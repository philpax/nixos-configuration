---
name: github-issue
description: Use when drafting or creating GitHub issues. Triggers on phrases like "create an issue", "draft an issue", "file a bug report", or when the user describes a problem that should be tracked as an issue.
---

# GitHub issue drafting and creation

## Workflow

1. **Gather context** — before writing, understand the problem:
   - Search the codebase for relevant code, comments, and docs related to the issue topic.
   - Check existing issues with `gh issue list --state all` to avoid duplicates and find related work.
   - If the user references a file, commit, or PR, read it for context.
   - Find the most recent commit hash that is relevant to the issue (the commit that introduced the code, fixed it, or is the current state). Use `git log --oneline -10 -- <path>` for file-scoped queries or `git rev-parse HEAD` for the current HEAD. Capture the **full 40-character SHA** with `git rev-parse` — GitHub only renders inline code previews for permalinks with the full SHA, not the abbreviated short hash.
   - Get the repo's GitHub URL with `git remote get-url origin` to build permalink URLs in the format `https://github.com/<owner>/<repo>/blob/<full-sha>/<path>#L<start>-L<end>`.

2. **Quiz the user** — the initial description is rarely enough. Before drafting, ask follow-up questions using the `question` tool. Ask about anything that's missing from this checklist:
   - **Severity / frequency**: Is it always reproducible, sporadic, or only under specific conditions?
   - **When it started**: Did it work before? If so, roughly when did it break — after a specific commit, config change, or game update?
   - **What was ruled out**: Has anything already been investigated and dismissed? This prevents re-investigating dead ends.
   - **Environment**: Build mode (debug/release), platform, game version, or any other relevant runtime context.
   - **Expected behaviour**: What *should* happen? Sometimes the user only describes what's broken.
   - **Scope**: Is this a single bug or multiple related symptoms? Should it be one issue or several?
   
   Don't ask all of these mechanically — only ask about what the user's description and the codebase context don't already answer. Batch the questions in a single `question` tool call so the user can answer them at once.

3. **Draft the issue** — write the issue body following the structure below, then show it to the user for review before creating. Never create an issue without showing the draft first.

4. **Create the issue** — after the user approves (or edits) the draft, create it with `gh issue create`.

## Issue structure

```
## Problem

One or two paragraphs describing what's wrong or what's needed. Lead with the
user-visible symptom or the missing capability, not the implementation detail.

## Context

Technical background: what system this touches, why it happens, what's been
investigated so far. Include file paths (`path/to/file.rs:line`), relevant
commits, and links to related issues or PRs.

Reference commits with their full short hash and a one-line description, so
the reference survives even if the code is later refactored or the line
numbers shift:

> Introduced in `f46b900` — the `RotateRenderFrameData` hook skipped
> `CKeep1000Frames` on eye 1, leaving the overflow count unreset.

For file references, use GitHub permalinks at the specific commit and line
range. GitHub renders these as inline code previews in the issue body, but
**only with the full 40-character SHA** — abbreviated short hashes render as
plain links without the preview:

> https://github.com/philpax/jc3vrs/blob/7456192fa31c4be25f0623001c619057a5c02be9/payload/src/hooks/game.rs#L73-L77

Build these from the repo URL, full commit SHA, file path, and line range
(`#L77` for a single line, `#L73-L77` for a range). Always pin to the
commit that represents the state of the code being described — not HEAD,
which may have drifted by the time someone reads the issue.

## Steps to reproduce (if applicable)

1. ...
2. ...

## Expected vs actual

**Expected:** ...
**Actual:**

## Proposed approach (if known)

Optional — skip if the solution isn't clear yet. Keep it brief; the issue is
for tracking the problem, not designing the fix.
```

## Guidelines

- Search the codebase for the root cause before writing — issues with concrete code references are far more useful than vague descriptions.
- Use GitHub permalinks (`https://github.com/<owner>/<repo>/blob/<full-40-char-sha>/<path>#L<start>-L<end>`) for file references. Pin to the commit that represents the state being described, not HEAD. GitHub renders these as inline code previews, but only with the full 40-character SHA — short hashes render as plain links.
- Reference commits by their full short hash with a one-line description of what the commit did, not just the bare hash. A reader should understand the reference without looking it up.
- Link related issues with `#NN` syntax.
- If the issue is a tentative fix (closing may be premature), use "Tentatively closes #NN" in the commit message rather than "Closes #NN" in the issue body.
- Check whether the repo uses labels with `gh label list`, and apply the appropriate ones. Common conventions: `bug` for things that are broken, `enhancement` for new features or capabilities. Add domain labels based on what systems the issue touches — check existing issues for the labeling pattern. If the issue fits a category that has no label, suggest creating one to the user rather than inventing it silently — don't create labels without asking. When editing an existing issue, verify its labels are still appropriate.
- Keep titles concise and specific: "Water boundary artifacts — underwater effect threshold" not "water bug".
- If the user gives a rough description, flesh it out with codebase context — don't just format their words. The value is in connecting the user's description to the actual code.
- When the issue describes a bug, include what was investigated and ruled out, not just what's broken. This saves the next person from re-investigating dead ends.
- For multi-part issues (e.g. "shadow artifacts" with two distinct causes), split into clearly labelled subsections rather than filing separate issues, unless the causes are truly independent.

## Creating the issue

After the user approves the draft:

```bash
gh issue create --title "..." --body "..."
```

- Use `--body-file` with a temp file if the body is long or contains backticks that break shell escaping.
- Add labels with `--label "bug"` if appropriate labels exist.
- Return the issue URL to the user.
