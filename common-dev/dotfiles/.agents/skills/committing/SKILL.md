---
description: Apply whenever staging or committing git work. Propose and get per-batch consent unless the user explicitly authorises scoped autocommits. Verify CI for the final commit; intermediate commits need not be CI-safe. Stage atomic commits and write bodies of 2-3 brief paragraphs.
---

# Committing responsibly

## Core principles

- **Propose before committing.** Show the user exactly what will be committed and get consent for that specific change, unless explicit autocommit authorisation covers it (see *Authorised autocommits*).
- **Consent is per-batch by default.** Permission to commit one set of changes is not permission to commit anything else. Each independent batch needs its own explicit go-ahead unless covered by scoped autocommit authorisation. Do not infer broader consent from a narrow approval.
- **Never commit unprompted.** Commit only at the user's request, after approval of a specific proposed commit, or under explicit autocommit authorisation.
- **Prefer atomic commits.** Even when many changes are in flight at once, each commit should be one coherent, independently reviewable change. Always consider whether the current changes can be split into separate independent commits before proposing.

## Workflow

1. **Inspect the current state.** Before proposing anything, see what's actually there:
   - `git status` — staged, unstaged, and untracked files.
   - `git diff` — unstaged changes.
   - `git diff --staged` — already-staged changes.
   - `git log --oneline -10` — recent commit style and message conventions for this repo.

2. **Group changes into logical commits.** Partition the working-tree changes into one or more independent, atomic commits. A good commit does one thing: a feature, a fix, a refactor, a doc update. Changes that are unrelated belong in separate commits.

3. **Consider splitting before proposing.** Before settling on a plan, ask whether each proposed commit can itself be split further — including by partial staging (`git add -p`, `git add <path>`) or by selectively reverting/unstaging parts of the working tree. Prefer more, smaller, coherent commits over fewer mixed ones.

4. **Stage and determine CI status.** For each batch, in order:
   - **Stage atomically** — exactly what this commit will contain, no more. Use `git add -p` / `git add <path>` for partial staging; avoid `git add -A` or `git add .` unless you intend to commit everything in the tree. Leave unrelated changes unstaged for their own commits.
   - **Determine CI status** — intermediate commits need not pass CI, and checks may be deferred until the final commit. Before the final commit, run the repo's check commands against its staged content (see *Verify CI for the final commit*). Fix failures and re-verify before proposing or autocommitting the final state.

5. **Propose the plan.** Unless scoped autocommit authorisation applies, present the commit plan before committing anything:
   - The list of commits, in the order you'll make them.
   - For each: the scope (which files/hunks), a draft commit message, the staging approach, and **CI verification status** (passed / failed / deferred until the final commit / couldn't verify, with what was run).
   - If you'd recommend splitting, say so explicitly and show the split.

6. **Get per-batch consent.** Unless scoped autocommit authorisation applies, wait for the user to approve a specific commit before committing it. If the user approves only part of the plan, commit only that part. Approval of commit N is not approval of commit N+1 unless the user explicitly approved both.

7. **Commit.** Run `git commit` with the approved message, or a message prepared under scoped autocommit authorisation. Include the required body in either case. Show the resulting commit (`git show --stat HEAD` or similar).

8. **Repeat for the next batch.** Return to step 1 for the remaining changes. Re-check whether consent or autocommit authorisation covers the next batch.

## Consent in detail

- "Commit this" means *this* set of changes — not everything in the working tree.
- If the user says "commit the fix" and the working tree also contains unrelated WIP, commit only the fix. Propose the WIP separately, or leave it alone.
- Approval of a three-commit plan covers those commits as described. If the split needs to change, stop and re-propose unless explicit autocommit authorisation covers the revised split.
- A "yes" to a proposed commit message is consent to commit that specific staged content with that message — not a standing OK to commit the rest of the tree.

## Authorised autocommits

Explicit user authorisation, such as "autocommit changes for this task" or "commit as you go during this session", permits commits within the stated scope without a separate proposal or confirmation for each batch. A request to implement a change does not authorise autocommits. If the scope or duration is unclear, ask before committing.

Authorisation applies only to the specified task, changes, or session. It ends when that scope is complete, the stated duration expires, or the user revokes it. Unrelated working-tree changes remain outside that authorisation. A change to a previously approved commit split still requires a new proposal unless autocommit authorisation covers it.

Autocommits still require state inspection, atomic staging, CI verification for the final commit, and the commit-message format below. Intermediate autocommits need not be CI-safe. Report the resulting commits and verification status. Autocommit authorisation does not authorise pushing, rewriting history, skipping hooks, or bypassing the final-commit CI requirement. If required final-state checks cannot be run, disclose the limitation and obtain explicit permission to commit with that verification gap unless the user already authorised that specific gap.

## Verify CI for the final commit

Only the final commit in a task or commit series must be CI-safe. Intermediate commits may fail CI or remain unchecked while the work is in progress. This applies to both individually approved commits and authorised autocommits. A standalone commit is also the final commit and must meet this requirement.

Before creating the final commit, verify the cumulative result using the repo's own check instructions. Do not declare the task complete with a failing final state or an unverified final state unless the user explicitly permits the disclosed verification gap. Report any deferred checks or known failures for intermediate commits and resolve them before the final commit. If the intended final commit fails checks, continue fixing the work rather than treating it as complete.

### Finding CI instructions

Look in this order; use the first that applies:
1. **CI config** — `.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`, `.circleci/config.yml`, `bitbucket-pipelines.yml`. Read the `on:`/`push:`/`pull_request:` triggers and the step list to see exactly what CI runs. Run the same commands locally.
2. **Repo docs** — `CONTRIBUTING.md`, `README.md`, `DEVELOPMENT.md`, `docs/development.md`, or a `Makefile`/`justfile`/`package.json` scripts section. Search for words like "test", "lint", "check", "ci", "verify".
3. **Convention** — if nothing is documented, ask the user how they run checks for this repo. Don't guess.

Common forms: `make ci` / `make test`, `just ci`, `cargo test` (+ `cargo fmt --check`, `cargo clippy -- -D warnings`), `npm test` / `npm run lint` / `pnpm test`, `pytest`, `tox`, `pre-commit run --all-files`.

### Running checks against the right state

- Run required final-state checks against the exact content of the final commit, including all earlier commits in the series, not unrelated working-tree changes. Stage first (step 4), then run the checks. If checks need a clean tree (no unstaged WIP), use `git stash -k` to temporarily set aside unstaged changes, run the checks, then `git stash pop`.
- Run checks before proposing or autocommitting the final commit, and again if its staged content changes. Checks on intermediate commits are optional.
- If a check is slow, tell the user how long it's taking rather than skipping it silently.

### When checks fail

- Intermediate commits may contain known CI failures. Disclose them and resolve them by the final commit. Do not create a final commit with known failures; fix and re-verify the cumulative result.
- If a required final-state check is genuinely impossible to run locally (needs secrets, special hardware, a remote service), disclose the limitation and obtain explicit permission to commit with that verification gap. Do not claim that the unverified final state is CI-safe.
- If CI is currently red on `main`/the base branch for unrelated reasons, call that out too, so the user isn't surprised when their commit doesn't go green.

### "Will this pass CI" vs "does this pass locally"

They're usually the same, but watch for gaps: CI may run extra jobs (matrix builds, cross-platform, doc builds) you can't fully reproduce. Do what you can locally, and for what you can't, reason about it from the CI config and tell the user what's unverified.

## When to split

Always consider splitting when any of these apply:
- A commit touches more than one concern (e.g. a bug fix + an unrelated refactor).
- Some changes are finished and others are still WIP.
- Tests, docs, and implementation could land separately and still make sense on their own.
- A large change is really several smaller changes bundled together.

Use `git add -p` to stage hunks selectively; `git restore --staged <path>` to unstage; selective staging or `git stash -k` to keep WIP out of a clean commit. Prefer moving stray changes into their own commit (or no commit) over bundling them into an unrelated one.

## Commit messages

Follow the repo's existing convention (check `git log --oneline`). Default to a concise imperative summary line (`Add …`, `Fix …`, `Refactor …`) under ~72 chars. Every commit must include a blank line followed by a body of 2-3 brief paragraphs explaining what the commit does and why. Describe the main changes and their effect; include relevant rationale or constraints without repeating the diff. This requirement also applies to autocommits. Reference issues with `#NN` only when genuinely related. Issue-closing trailers do not count toward the 2-3 explanatory paragraphs.

Write the body in the register the `plain-technical-prose` skill defines: short declarative sentences, third person, no bold or emphasis constructions. A commit message states what changed and why it changed, without selling the change.

**Closing issues:** When a commit resolves an issue, put `Closes #N` in the commit **body** (the description), never in the summary heading. The heading should describe the change itself, not the issue-closure bookkeeping. For example:

```
Fix off-by-one in token refresh window

The expiry check now compares against the correct bound. Tokens remain valid until the intended refresh window.

The previous bound caused premature refresh under load. The corrected comparison avoids unnecessary refresh requests.

Closes #142
```

## Don't

- Don't commit before proposing unless explicit autocommit authorisation covers the change.
- Don't create the final commit without CI verification, unless the user explicitly permits a disclosed verification gap. Intermediate commits need not be CI-safe.
- Don't let one consent cover unrelated commits.
- Don't bundle unrelated changes to save a step.
- Don't use `git add -A` to commit everything when only part of the tree is approved.
- Don't amend or rewrite already-pushed history without explicit instruction.
