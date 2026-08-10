---
description: Use when proposing a PR title and description for the current branch. Triggers on phrases like "propose a PR", "draft a PR description", "write the PR for this branch", or when the user asks to prepare a pull request for the current work.
---

# PR title and description proposal

## Workflow

1. **Gather context.** Collect the branch and its changes before writing:
   - `git branch --show-current`: the branch name drives the title.
   - The base branch. `git symbolic-ref refs/remotes/origin/HEAD` reports the default. Use the default unless the user names another target.
   - `git log --oneline <base>..HEAD`: the commits unique to the branch.
   - `git diff --stat <base>...HEAD`, then read the changed files. The diff is the primary source of what the PR does.
   - `git status`: whether uncommitted work belongs with the branch.
   - `git remote get-url origin`: the repo URL, for links and to name the remote.
   - `gh pr view`: whether a PR already exists for this branch. An existing draft PR is updated, not duplicated.
   - `gh pr list --state merged --limit 10`: the repo's title and description conventions.

2. **Ask when unclear.** Ask follow-up questions with `ask_user_question` before drafting, for anything the code does not answer: the target branch, draft versus ready state, whether uncommitted work belongs in the PR, and who will review it. When the user has not specified an issue that the PR closes, ask whether one exists; the issue number then becomes the final `Closes #NN` line of the description. Batch the questions into a single call (up to four questions). Do not ask mechanically; ask only about the gaps the gathered context does not close.

3. **Draft the proposal.** Write the title and description in the register the `plain-technical-prose` skill defines, following the shape below. The description is not line-wrapped: each paragraph is a single source line, and a newline ends a paragraph. Wrap inline code, keywords, commands, file paths, and identifiers in backticks.

4. **Present and iterate.** Show the full draft to the user. Wait for the user to confirm that they have read it before raising the consent question. Apply feedback and re-show the updated draft; after a revision, wait again for a fresh read confirmation. A correction or follow-up is feedback on the draft, not consent to create the PR.

5. **Get explicit consent.** Raise the consent question only after the user has confirmed reading the current draft. Creating the PR requires very clear consent. A statement that the draft looks good confirms reading but is not consent. Before asking, restate exactly what will be created: the title, the target branch, whether the PR opens as a draft, and the description. Only an explicit instruction to create or open the PR counts as consent. Use `ask_user_question` with a dedicated "Create the PR now?" question when the user has not given an unambiguous go-ahead; a single-select question that restates the exact values to be used is the clearest form of consent.

6. **Create or update the PR.** After clear consent, create with `gh pr create` or update an existing PR with `gh pr edit`. Follow the Creating the PR section below. Return the resulting URL.

## Title and description shape

The title names the change in one clause: the component and what it now does. Keep it short enough for the repo's convention. "Add branch-aware PR drafting to `pr-propose`" names the component and the change; "improvements and fixes" does not.

The description uses sections in this order; omit the ones that do not apply:

```
## Summary

One or two sentences stating what the branch does, from the reader's perspective. Lead with the outcome, not the implementation detail.

## Context

Why the change exists. Name the problem the change solves and what the reader must know to review it.

## Changes

Up to two paragraphs describing the change at a high level. Do not recap the diff; the diff is visible in the PR. Wrap identifiers, paths, and commands in backticks.

## Testing

How the change was verified. State "Not tested" when it was not, and "Needs testing" for parts that remain unverified.

## Notes

Caveats, follow-up work, breaking changes, and screenshots. Omit the section when there is nothing to note.

Closes #NN
```

The block above is the final format: each paragraph is a single source line, and a newline ends a paragraph. `Closes #NN` is the final line of the description when the PR closes an issue, and is omitted when it closes none. Write the placeholder as "Closes #NN" with the real number, or omit the line entirely.

## Creating the PR

Create with `gh pr create`, or update an existing PR with `gh pr edit`.

- Write the description to a temp file and pass `--body-file`. Backticks in the body break inline shell quoting.
- Pass `--base <branch>` when the target is not the default branch.
- Pass `--draft` when the user wants the PR to open as a draft.
- Return the PR URL to the user.