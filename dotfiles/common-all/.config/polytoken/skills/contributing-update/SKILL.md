---
description: Use when a project's CONTRIBUTING.md was built from philpax/contributing-templates and should be refreshed against the latest upstream templates. Computes what actually changed, proposes the merge, and applies it locally only after the user verifies the execution parameters (subagent use, coverage, and so on).
---

# Updating a CONTRIBUTING.md from contributing-templates

## What this is for

The local CONTRIBUTING.md was initialised from the templates and has since diverged on purpose: project-specific sections, local amendments inside template sections, rules the project settled on its own. Upstream keeps evolving. This skill refreshes the template-derived parts while preserving the divergence, and gets explicit sign-off on how the change is executed before touching the file.

The templates explicitly aren't a source of truth to sync back to, but the reverse direction is worth doing periodically: when several projects independently arrive at the same rule, it belongs upstream.

## Workflow

1. **Find the source set.** Look for the sync marker written by `contributing-init` (`<!-- contributing-templates: files=… @ … -->`). If it's there, that's the file list and the last-known upstream state. If it's not, determine which templates apply with the same rules as `contributing-init` (language manifests, framework usage) — and if the section layout has diverged enough to make that guess shaky, ask the user which files were used originally.

2. **Fetch the current state.** Read the local CONTRIBUTING.md, then pull each template from `https://raw.githubusercontent.com/philpax/contributing-templates/main/<file>.md`.

3. **Compute what changed, section by section.** For each template-derived section, compare the local copy against the new template:
   - New rules, rewritten bullets, and removed conventions upstream.
   - Local amendments embedded in that section — edits the project made on top of the template. These must be preserved.
   - Sections that have diverged heavily (a local rewrite, not a light edit). Don't silently rewrite those: mark them as a user decision between keeping the local version, adopting upstream, or merging by hand.

4. **Propose the merge with a concrete diff.** Show what would change — a unified diff of the proposed CONTRIBUTING.md, or at least a section-by-section list of adopt / amend / skip. The project-specific sections are untouched and don't need to be in the diff.

5. **Offer to apply it locally — after the user verifies the execution parameters.** Use `ask_user_question` before applying. Verify, at minimum:
   - **Consent to apply.** Does the user want the updated file written now, or just the diff handed over?
   - **Subagent use.** Apply inline in this session, or delegate the mechanical re-composition to a subagent (and at what capability level)? Default to inline; consider a subagent when the file is large or the session is already loaded. Say what you'd delegate rather than asking vaguely.
   - **Coverage.** Adopt all upstream changes, or a subset — e.g. only the changes in `general.md`, or only specific sections? If selective, get the list.
   - **Working-tree state.** If CONTRIBUTING.md has uncommitted local edits, say how you'll treat them (merge against them, leave them alone) before writing.

   Skip any parameter that's already unambiguous — don't run a questionnaire out of habit.

6. **Apply.** Merge per the agreed plan: adopt the selected upstream changes, preserve local amendments and project-specific sections, and update the sync marker with the new upstream commit or date. Keep the templates' own conventions while editing. Then verify the `CLAUDE.md` / `AGENTS.md` symlinks still resolve to CONTRIBUTING.md (they usually do — confirm rather than assume).

7. **Report.** Summarise what changed and why ("general.md gained a testing rule; rust.md rewrote the error-handling section; adopted, with the local amendments preserved"), what was skipped and why, and that anything several projects converge on belongs back upstream.

## Don't

- Don't overwrite the local copy with raw template output — the project-specific sections and local amendments are the point of the local copy.
- Don't apply without consent, and don't apply before the execution parameters are verified when there's any doubt.
- Don't silently drop a local amendment inside a template section when adopting upstream changes.
- Don't commit the result without explicit permission; if asked, follow the `committing` skill.