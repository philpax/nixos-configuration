---
description: Use when quickly capturing a problem as a GitHub issue without deep investigation. Triggers on phrases like "quick issue", "file this for later", "track this", or when the user wants to note something to pick up later. For thorough issue drafting with codebase investigation, use the github-issue skill instead.
---

# Quick GitHub issue creation

## Scope

Capture the problem fast, without codebase investigation, commit archaeology, or permalink construction. Write what the user has already reported, fill the gaps by asking, file the issue, and move on. The issue exists so the problem is not forgotten, and details can be expanded when someone picks it up.

Use the `github-issue` skill instead when permalinks, commit references, detailed reproduction steps, or a thorough investigation are needed before filing.

## Workflow

1. **Identify gaps.** Check the user's description for anything missing that would make the issue hard to pick up later. Common gaps:
   - What should happen, as well as what is broken
   - When it started, or whether it always behaved this way
   - Scope: one issue or several related symptoms

   Do not search the codebase or dig through commits. Rely on the user's description.

2. **Ask for clarification.** If a gap would make the issue ambiguous, ask the user to fill it in using `ask_user_question`. Keep it light: batch the questions in a single call, ask only what is genuinely needed, and skip the questionnaire entirely if the description is already clear enough to act on later. Each question supports free-text answers, so do not add a separate "other" option.

3. **Write the issue.** Draft a title and body from the user's description plus any clarification they provided. Follow the `github-issue-prose-style` skill for the register, the title, and the reader it is written for. Speed is the point here, and the plain register is the faster one to write.

4. **Show the draft.** Present the title and body to the user for a quick review.

5. **Create the issue.** Do this only after the user gives emphatic affirmative consent (e.g. "looks good", "ship it", "go ahead and create it"). See "Consent" below.

## Consent

`gh issue create` must not run until the user explicitly approves creation.

A correction or follow-up (answering a clarification question, asking for a wording change, pointing out a missing detail) is feedback on the draft, not consent to create it. Apply the feedback, re-show the updated draft, and wait for an explicit go-ahead before moving to creation.

Do not infer approval from the user merely responding to the draft. If there is any ambiguity about whether they want it created now, ask.

## Issue structure

```
## Problem

One or two sentences describing what's wrong or what's needed. Lead with the user-visible symptom.

## Notes (optional)

Any context the user provided — file paths, error messages, when it started, what was ruled out. Skip this section if there is nothing to add.
```

Keep the title to a single clause. A defect names the component and the symptom; work names the change as a verb phrase rather than the end state it produces.

A short issue still has to be actionable later by someone holding part of the context, so a term the description depends on is defined even in two sentences.

## Creating the issue

```bash
gh issue create --title "..." --body "..."
```

- Use `--body-file` with a temp file if the body contains backticks.
- Check `gh label list` for appropriate labels and add them with `--label`.
- Do not create labels without asking.
- Return the issue URL to the user.
