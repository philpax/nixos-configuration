---
description: Use when drafting or creating GitHub issues. Triggers on phrases like "create an issue", "draft an issue", "file a bug report", or when the user describes a problem that should be tracked as an issue.
---

# GitHub issue drafting and creation

## Workflow

1. **Gather context.** Before writing, understand the problem:
   - Search the codebase for relevant code, comments, and docs related to the issue topic.
   - Check existing issues with `gh issue list --state all` to avoid duplicates and find related work.
   - If the user references a file, commit, or PR, read it for context.
   - Find the most recent commit hash that is relevant to the issue (the commit that introduced the code, fixed it, or is the current state). Use `git log --oneline -10 -- <path>` for file-scoped queries or `git rev-parse HEAD` for the current HEAD. Capture the full 40-character SHA with `git rev-parse`: GitHub renders inline code previews only for permalinks with the full SHA, not for the abbreviated short hash.
   - Get the repo's GitHub URL with `git remote get-url origin` to build permalink URLs in the format `https://github.com/<owner>/<repo>/blob/<full-sha>/<path>#L<start>-L<end>`.

2. **Quiz the user.** The initial description is rarely enough. Before drafting, ask follow-up questions using the `ask_user_question` tool. Ask about anything that is missing from this checklist:
   - **Severity / frequency**: Is it always reproducible, sporadic, or only under specific conditions?
   - **When it started**: Did it work before? If so, roughly when did it break: after a specific commit, a config change, or a game update?
   - **What was ruled out**: Has anything already been investigated and dismissed? This prevents re-investigating dead ends.
   - **Environment**: Build mode (debug/release), platform, runtime version, or any other relevant runtime context.
   - **Expected behaviour**: What should happen? Sometimes the user only describes what is broken.
   - **Scope**: Is this a single bug or multiple related symptoms? Should it be one issue or several?

   Do not ask all of these mechanically. Ask only about what the user's description and the codebase context do not already answer. Batch the questions in a single `ask_user_question` tool call (up to four questions) so the user can answer them at once. Each question supports free-text answers, so do not add a separate "other" option.

3. **Draft the issue.** Write the issue body following the structure below, then show it to the user for review. Do not create the issue until the user explicitly approves. Iterate on the draft until the user gives affirmative consent before proceeding to creation.

   A correction or follow-up (answering an open question, asking for a wording change, pointing out a missing detail) is feedback on the draft, not consent to create it. Apply the feedback, re-show the updated draft, and wait for an explicit go-ahead (e.g. "looks good", "ship it", "go ahead and create it") before moving to creation. Do not infer approval from the user merely responding to the draft.

4. **Create the issue.** After the user gives affirmative consent (a correction or follow-up does not count), create it with `gh issue create`.

## Issue structure

```
## Problem

One or two paragraphs describing what's wrong or what's needed. Lead with the user-visible symptom or the missing capability, not the implementation detail.

## Context

Technical background: what system this touches, why it happens, what's been investigated so far. Include file paths (`path/to/file.rs:line`), relevant commits, and links to related issues or PRs.

Reference commits with their full short hash and a one-line description, so the reference survives even if the code is later refactored or the line numbers shift:

> Introduced in `a1b2c3d` — the hook skipped the counter reset on the second pass, leaving the overflow count unreset.

For file references, use GitHub permalinks at the specific commit and line range. GitHub renders these as inline code previews in the issue body, but **only with the full 40-character SHA** — abbreviated short hashes render as plain links without the preview:

> https://github.com/<owner>/<repo>/blob/<full-40-char-sha>/<path/to/file.rs>#L73-L77

Build these from the repo URL, full commit SHA, file path, and line range (`#L77` for a single line, `#L73-L77` for a range). Always pin to the commit that represents the state of the code being described — not HEAD, which may have drifted by the time someone reads the issue.

## Steps to reproduce (if applicable)

1. ...
2. ...

## Expected vs actual

**Expected:** ...
**Actual:**

## Proposed approach (if known)

Optional — skip if the solution isn't clear yet. Keep it brief; the issue is for tracking the problem, not designing the fix.
```

For an issue describing work rather than a defect, use these sections instead:

```
## Current state

What exists now: the current behaviour, the missing capability, or the constraint that applies. Terms used later are introduced here.

## Change

The work, stated as behaviour rather than as a task list. Where an alternative was considered and rejected, name it and the reason.

## Done when

One sentence, checkable by someone other than the author, naming the form of verification: a test, a measurement, a recorded decision.
```

## Guidelines

- Write the body following the `github-issue-prose-style` skill, which sets the title form, the structure of a work issue, and the reader an issue is written for, and which takes its register from `plain-technical-prose`. The section headings and the `**Expected:**` / `**Actual:**` labels in the structure above are structural and stay; other bold is emphasis and does not belong.
- Search the codebase for the root cause before writing: an issue with concrete code references is more useful than a vague description.
- Use GitHub permalinks (`https://github.com/<owner>/<repo>/blob/<full-40-char-sha>/<path>#L<start>-L<end>`) for file references. Pin to the commit that represents the state being described, not HEAD. GitHub renders these as inline code previews, but only with the full 40-character SHA. Short hashes render as plain links.
- Reference commits by their full short hash with a one-line description of what the commit did, not just the bare hash. A reader should understand the reference without looking it up.
- Link related issues with `#NN` syntax.
- If the issue is a tentative fix (closing may be premature), use "Tentatively closes #NN" in the commit message rather than "Closes #NN" in the issue body.
- Check whether the repo uses labels with `gh label list`, and apply the appropriate ones. Common conventions: `bug` for things that are broken, `enhancement` for new features or capabilities. Add domain labels based on what systems the issue touches, and check existing issues for the labelling pattern. If the issue fits a category that has no label, suggest creating one to the user rather than inventing it silently; do not create labels without asking. When editing an existing issue, verify its labels are still appropriate.
- Keep titles to one clause. A defect names the component and the symptom ("Login form ignores submit on second click", not "login bug"). Work names the change as a verb phrase ("Cache materialised state with a high-water mark"), never the end state it produces. A title that does not fit in one clause may mean the issue is too broad; consider splitting it. Do not append a second explanatory clause after an em-dash or comma. The title names the problem, and the body explains it. ✅ "Frobnicator's encabulator requires tuning" ❌ "Frobnicator's encabulator requires tuning — maximize efficiency in system"
- An issue is read alone, out of order, and without the conversation that produced it. Define each term it uses, and do not position a sentence against a document or a list the reader does not have.
- If the user gives a rough description, flesh it out with codebase context rather than formatting their words. The value is in connecting the user's description to the actual code.
- When the issue describes a bug, include what was investigated and ruled out, not just what is broken. This saves the next person from re-investigating dead ends.
- For multi-part issues (e.g. "shadow artifacts" with two distinct causes), split into clearly labelled subsections rather than filing separate issues, unless the causes are truly independent.

## Creating the issue

After the user approves the draft:

```bash
gh issue create --title "..." --body "..."
```

- Use `--body-file` with a temp file if the body is long or contains backticks that break shell escaping.
- Add labels with `--label "bug"` if appropriate labels exist.
- Return the issue URL to the user.
