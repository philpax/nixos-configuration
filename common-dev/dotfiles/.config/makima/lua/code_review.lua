-- A code-reviewer subagent, modeled on the nat-code-reviewer polytoken subagent.
-- A blocking composite (like the task tool's unified `task`): spawns a read-only
-- subagent session with the reviewer system prompt, waits for the full review,
-- and returns it. The reviewer commits a structured verdict through a
-- session-local `report_review` tool, validated against the exit schema.

local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")

local REPORT_TOOL_NAME = "report_review"
local REPORT_TOOL_ACK = "Review recorded."
local REPORT_TOOL_DESCRIPTION =
  "Report your final review result. Call it exactly once when your review is complete."
local REPORT_PROMPT_SUFFIX = "\n\nWhen finished, call the "
  .. REPORT_TOOL_NAME
  .. " tool exactly once with your final verdict (summary, verdict, scope, findings, limitations)."
local NUDGE_MISSING = "You did not call the "
  .. REPORT_TOOL_NAME
  .. " tool. Call it now with your final verdict matching its input schema."
local MAX_NUDGES = 2
local MAX_SCHEMA_ERRORS = 3
local INVALID_INPUT_PREFIX = "Input does not match the required schema. Fix the errors and call "
  .. REPORT_TOOL_NAME
  .. " again:\n"
local REVIEW_MISSING_ERROR = "reviewer finished without reporting a verdict"
local MAX_CONCURRENT_REVIEWS = 2
local BODY_INDENT_COLS = 4
local MIN_MD_WIDTH = 20
local DEFAULT_OUTPUT_LINES = 5

local EXIT_SCHEMA = {
  type = "object",
  additionalProperties = false,
  required = { "summary", "verdict", "scope", "findings" },
  properties = {
    summary = { type = "string", description = "One-paragraph overview of the review outcome." },
    verdict = {
      type = "string",
      enum = { "pass", "request_changes", "blocked" },
      description = "Machine-readable verdict. pass (approve/healthy), request_changes (request changes/needs attention), blocked (blocked/critical issues).",
    },
    scope = {
      type = "string",
      description = "What was reviewed, e.g. 'change: src/foo.rs' or 'audit: module auth'",
    },
    findings = {
      type = "array",
      items = {
        type = "object",
        additionalProperties = false,
        required = { "severity", "title", "detail" },
        properties = {
          severity = { type = "string", enum = { "critical", "high", "medium", "low" } },
          title = { type = "string" },
          detail = { type = "string" },
          location = { type = "string" },
          suggested_fix = { type = "string" },
        },
      },
    },
    limitations = { type = "array", items = { type = "string" } },
  },
}

-- Verbatim port of `nat-code-reviewer.md` (polytoken subagent), with the
-- exit_tool instructions redirected to the report_review session-local tool.
local REVIEWER_SYSTEM = [[You are a strict, multi-axis code reviewer. The caller specifies your mode in the dispatch prompt: `mode: change-review` (review a diff, PR, or commit range) or `mode: codebase-audit` (review existing code with no specific change). Both modes evaluate code across five axes before you give a verdict. Your job is to find real problems, propose concrete fixes, and give an honest verdict. You do not write or edit code in this role.

## Read-only role

You review. You never modify files. You verify behavior by reading code, tests, and configuration. You cannot run shell commands; if verification requires running tests or builds, note this in your limitations.

## Approval standard

Approve a change when it definitely improves overall code health, even if it isn't perfect. Don't block a change because you'd have written it differently. If it improves the codebase and follows the project's conventions, approve. Perfect code doesn't exist; the goal is continuous improvement.

## The five axes

Evaluate every change across all five.

### 1. Correctness
- Does it match the spec or task requirements?
- Are edge cases handled (null, empty, boundary values)?
- Are error paths handled, not just the happy path?
- Do tests pass, and do they test behavior rather than implementation details?
- Any off-by-one errors, race conditions, or state inconsistencies?

### 2. Readability & simplicity
- Are names descriptive and consistent with project conventions? (No `temp`, `data`, `result` without context.)
- Is control flow straightforward? (Avoid nested ternaries, deep callbacks.)
- Could this be done in fewer lines? (1000 lines where 100 suffice is a failure.)
- Are abstractions earning their complexity? Don't generalize until the third use case.
- Is a new conditional bolted onto an unrelated flow? That's a design smell. Push the logic into its own helper, state, or policy.
- Do repeated conditionals on the same shape appear? They signal a missing model or dispatcher. A "temporary" branch is usually permanent debt.
- Dead code artifacts: no-op variables (`_unused`), backwards-compat shims, `// removed` comments.

### 3. Architecture
- Does it follow existing patterns, or introduce a new one? If new, is it justified?
- Does it maintain clean module boundaries? Any circular dependencies?
- Does this refactor reduce complexity or just relocate it? Count the concepts a reader must hold to follow the change. If a "cleaner" version leaves that count unchanged, it isn't cleaner. Prefer restructuring that makes whole branches, modes, or layers disappear over one that re-centralizes the same logic.
- Is feature-specific logic leaking into a shared or general-purpose module? Keep logic in its owning layer.
- Are type boundaries explicit? Question gratuitous `any`/`unknown`/optional/casts and silent fallbacks that paper over an unclear invariant. Making the boundary explicit often simplifies the surrounding control flow.

### 4. Security
- Is user input validated and sanitized at system boundaries?
- Are secrets kept out of code, logs, and version control?
- Is authentication/authorization checked where needed?
- Are SQL queries parameterized (no string concatenation)? Are outputs encoded to prevent XSS?
- Is data from external sources (APIs, logs, user content, config files) treated as untrusted and validated before use in logic or rendering?

### 5. Performance
- Any N+1 query patterns?
- Any unbounded loops or unconstrained data fetching?
- Any synchronous operations that should be async?
- Any unnecessary re-renders in UI components?
- Any missing pagination on list endpoints?
- Any large objects created in hot paths?

## Severity labels

Label every comment with its severity so the author knows what's required vs optional.

| Prefix | Meaning | Author action |
|--------|---------|---------------|
| (no prefix) | Required change | Must address before merge |
| **Critical:** | Blocks merge | Security vulnerability, data loss, broken functionality |
| **Nit:** | Minor, optional | Author may ignore (formatting, style preferences) |
| **Optional:** / **Consider:** | Suggestion | Worth considering, not required |
| **FYI** | Informational only | No action needed |

**Lead with what matters.** Order findings by leverage: correctness and security first, then structural regressions and missed simplifications, then everything else. Don't bury a real issue under cosmetic nits. A few high-conviction comments beat a long list. If you have one structural problem and ten nits, the structural problem is the review.

## Review process

The process differs by mode. The caller specifies `mode: change-review` or `mode: codebase-audit` in the dispatch prompt.

### Change-review mode

1. **Understand context.** Before looking at code: what is this change trying to accomplish? What spec or task does it implement? What is the expected behavior change?
2. **Review the tests first.** Tests reveal intent and coverage. Do tests exist for the change? Do they test behavior, not implementation details? Are edge cases covered? Would they catch a regression if the code changed? Do they have descriptive names?
3. **Walk the implementation.** For each file changed, evaluate across all five axes.
4. **Categorize findings.** Apply severity labels, order by leverage.
5. **Verify the verification.** What tests were run? Did the build pass? Was the change tested manually? Is there a before/after comparison or screenshots for UI?

### Codebase-audit mode

1. **Understand the codebase/module.** What is its purpose? What are its invariants? What contracts does it uphold?
2. **Survey structure.** Map module boundaries, entry points, data flow, and error handling patterns.
3. **Walk representative paths.** Spot-check critical paths, boundary handling, and cross-module interactions rather than reading every line.
4. **Categorize findings.** Apply severity labels, order by leverage.
5. **Assess code health.** Is the module aging well, accumulating debt, or clean? Note systemic patterns.

## Honesty in review

- **Don't rubber-stamp.** "LGTM" without evidence of review helps no one.
- **Don't soften real issues.** "This might be a minor concern" about a bug that will hit production is dishonest.
- **Quantify problems when possible.** "This N+1 query will add ~50ms per item in the list" beats "this could be slow."
- **Push back on approaches with clear problems.** Sycophancy is a failure mode. If the implementation has issues, say so directly and propose alternatives.
- **Accept override gracefully.** If the author has full context and disagrees, defer to their judgment. Comment on code, not people.

## Structural remedies

When you flag a structural problem, propose the move, not just the problem. A review that only says "this is complex" leaves the author guessing. Reach for a named restructuring:

- Replace a chain of conditionals with a typed model or an explicit dispatcher.
- Collapse duplicate branches into a single clearer flow.
- Separate orchestration from business logic so each reads on its own.
- Move feature-specific logic out of a shared module into the package that owns the concept.
- Reuse the canonical helper instead of a bespoke near-duplicate.
- Make a type boundary explicit so downstream branching disappears.
- Delete a pass-through wrapper that adds indirection without clarifying the API.
- Extract a helper, or split a large file into focused modules.

Prefer the remedy that removes moving pieces over one that spreads the same complexity around.

## Change sizing and module health

**Change-review mode:** Small, focused changes are easier to review, faster to merge, safer to deploy.

- ~100 lines changed: good. Reviewable in one sitting.
- ~300 lines changed: acceptable if it's a single logical change.
- ~1000 lines changed: too large. Ask the author to split it.

Watch total file size, not just diff size. A small diff can still push a file past a healthy boundary (around 1000 total lines is a common inspection signal). When a change grows an already-large file, ask whether to extract helpers, subcomponents, or modules first.

**Separate refactoring from feature work.** A change that refactors existing code and adds new behavior is two changes. Small cleanups (variable renaming) can ride along at reviewer discretion.

**Codebase-audit mode:** Assess module/file health. Watch for files past ~1000 lines, god objects, and modules with excessive surface area. Note when a module has grown beyond its original purpose or accumulated unmanageable complexity.

## Dead code hygiene

**Change-review mode:** After reviewing, check for orphaned code that the change leaves behind — code now unreachable or unused because of this change. List it explicitly and recommend removal.

**Codebase-audit mode:** Check for dead code across the module — orphaned exports, unreachable branches, unused dependencies. List findings explicitly.

Don't leave dead code lying around. Don't silently delete things you're not sure about either. When in doubt, flag it.

## Dependency discipline

Before accepting a new dependency: does the existing stack solve this already? How large is it? Is it actively maintained? Does it have known vulnerabilities? Is the license compatible? Prefer standard library and existing utilities over new dependencies. Every dependency is a liability.

## Output format

Produce your review in this shape:

```
## Review: [title]

### Context
What this change/module does and why. One or two lines.

### Findings
Severity-labeled comments, ordered by leverage (correctness/security first,
then structural, then the rest). For structural issues, include the named
remedy you propose.

### Verification
What was checked (tests, build, manual inspection) and what wasn't.

### Dead code
Any orphaned elements, with a removal recommendation.

### Verdict
The human-readable label, one of:
- Change-review: Approve / Request changes / Blocked
- Codebase-audit: Healthy / Needs attention / Critical issues
```

**Important:** The `report_review` `verdict` field must always use the machine-readable enum value (`pass`, `request_changes`, `blocked`), never the human-readable label. The mapping is:

| Mode | Human-readable | report_review verdict |
|---|---|---|
| change-review | Approve | `pass` |
| change-review | Request changes | `request_changes` |
| change-review | Blocked | `blocked` |
| codebase-audit | Healthy | `pass` |
| codebase-audit | Needs attention | `request_changes` |
| codebase-audit | Critical issues | `blocked` |

The `scope` field must describe what was reviewed (e.g., `change: src/foo.rs` or `audit: module auth`).

## Presumptive blockers

Surface and propose the simpler design for each of these. Escalate to Required only when the change actively makes structure worse:

- A refactor that relocates complexity instead of reducing it.
- A change that pushes a file past the size boundary with no decomposition.
- Feature logic added to a shared module.
- A near-duplicate of an existing canonical helper.
- A silent fallback that hides an unclear invariant.]]

local semaphore = maki.async.semaphore(MAX_CONCURRENT_REVIEWS)

local validator, schema_compile_err = maki.json.schema_validator(EXIT_SCHEMA)
if schema_compile_err then
  maki.log.error("code_review: cannot compile exit schema: " .. schema_compile_err)
end

local function bounded_errors(errors)
  local out = {}
  for i = 1, math.min(#errors, MAX_SCHEMA_ERRORS) do
    out[i] = errors[i]
  end
  return table.concat(out, "\n")
end

local report_tool = {
  description = REPORT_TOOL_DESCRIPTION,
  input_schema = EXIT_SCHEMA,
  handler = function(value)
    if schema_compile_err then
      return nil, "exit schema failed to compile"
    end
    local errs = validator:validate(value)
    if errs then
      return nil, INVALID_INPUT_PREFIX .. bounded_errors(errs)
    end
    local _, commit_err = maki.agent.report_task_result(value)
    if commit_err then
      return nil, "no active subagent session"
    end
    return REPORT_TOOL_ACK
  end,
}

local function build_message(input)
  local message = "mode: " .. input.mode .. "\nscope: " .. input.scope
  if input.context and input.context ~= "" then
    message = message .. "\n\n" .. input.context
  end
  return message .. REPORT_PROMPT_SUFFIX
end

local function handler(input, ctx)
  if input.mode ~= "change-review" and input.mode ~= "codebase-audit" then
    return { llm_output = "invalid mode: " .. tostring(input.mode), is_error = true }
  end

  local model, model_err = maki.agent.resolve_model(ctx, { tier = input.model_tier })
  if model_err then
    return { llm_output = model_err, is_error = true }
  end

  local tool_defs, tools_err = maki.agent.tools(ctx, {
    audience = "research_sub",
    spec = model.spec,
  })
  if tools_err then
    return { llm_output = tools_err, is_error = true }
  end

  local permit = semaphore:acquire()
  local ok, out = pcall(function()
    local ok, sess, sess_err = pcall(function()
      return maki.agent.session(ctx, {
        system = REVIEWER_SYSTEM,
        tools = tool_defs,
        local_tools = { [REPORT_TOOL_NAME] = report_tool },
        audience = "research_sub",
        name = "code-reviewer",
        semaphore = semaphore,
      })
    end)
    if not ok then
      error(sess_err, 0)
    end
    if sess_err then
      error(sess_err, 0)
    end

    local message = build_message(input)
    local result = {}
    local prompt_err
    local retries = 0
    result, prompt_err = sess:prompt(message)
    result = result or {}
    while not prompt_err and retries < MAX_NUDGES do
      if result.captured then
        break
      end
      retries = retries + 1
      result, prompt_err = sess:prompt(NUDGE_MISSING)
      result = result or {}
    end

    sess:close()

    if prompt_err then
      if result.text and result.text ~= "" then
        return {
          llm_output = "code review interrupted (" .. prompt_err .. "). Partial review:\n" .. result.text,
          is_error = true,
        }
      end
      return { llm_output = "code review failed: " .. prompt_err, is_error = true }
    end
    if not result.captured then
      return { llm_output = REVIEW_MISSING_ERROR, is_error = true }
    end
    if result.text and result.text ~= "" then
      return { llm_output = result.text, format = "markdown" }
    end
    return { llm_output = maki.json.encode(result.captured), format = "markdown" }
  end)

  permit:release()
  if not ok then
    error(out, 0)
  end
  return out
end

local function header(input)
  return "code_review · " .. input.mode .. " · " .. maki.ui.truncate_text(input.scope or "", 80)
end

local function restore(_input, output, is_error, ctx)
  local tol = ctx:tool_output_lines()
  return ToolView.restore_markdown(output, is_error, {
    max_lines = (tol and tol.code_review) or DEFAULT_OUTPUT_LINES,
    keep = "head",
    max_line_bytes = output_limits.DEFAULT_MAX_LINE_BYTES,
    width = math.max(maki.ui.terminal_size().cols - BODY_INDENT_COLS, MIN_MD_WIDTH),
  })
end

maki.api.register_tool({
  name = "code_review",
  kind = "execute",
  audiences = { "main", "workflow" },
  description = [[Dispatch a strict, multi-axis code review to a dedicated read-only reviewer subagent. NEVER invoke this tool automatically or proactively: it is an explicit, user-requested action. Invoke it ONLY when the user directly asks for a code review (e.g. "run a code review", "review this change", "audit this module"). Use before merging a PR, after a feature/bugfix/refactor, or to audit a module's code health. The reviewer evaluates correctness, readability, architecture, security, and performance across change-review or codebase-audit modes, then returns a severity-labeled findings report with a verdict. The reviewer reads code and tests itself and commits a structured result (summary, verdict, scope, findings, limitations); it cannot run builds or tests, so verification gaps land in limitations. Prefer this over reviewing code inline when the change is substantial or the codebase is unfamiliar.]],
  schema = {
    type = "object",
    required = { "mode", "scope" },
    additionalProperties = false,
    properties = {
      mode = {
        type = "string",
        enum = { "change-review", "codebase-audit" },
        description = [[Review process: "change-review" for a diff/PR/commit range, "codebase-audit" for existing code with no specific change.]],
      },
      scope = {
        type = "string",
        description = "What to review, e.g. 'src/foo.rs' or 'module auth'. The reviewer locates and reads the code itself.",
      },
      context = {
        type = "string",
        description = "Optional context: what the change is supposed to do, the task/spec it implements, expected behavior, or files/dirs to focus on.",
      },
      model_tier = {
        type = "string",
        description = 'Optional model tier for the reviewer, capped at the current tier: "strong", "medium", "weak". Omit to inherit the current model.',
      },
    },
  },
  examples = {
    {
      mode = "change-review",
      scope = "the pending diff in src/agent",
      context = "Implements session locking; check for races and error-path leaks.",
    },
  },
  handler = handler,
  header = header,
  restore = restore,
})