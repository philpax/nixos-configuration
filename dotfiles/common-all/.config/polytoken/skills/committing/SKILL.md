---
description: Apply whenever staging or committing git work. Propose before committing, get per-batch consent, verify CI passes first, and split changes into clean atomic commits via partial staging.
---

# Committing responsibly

## Core principles

- **Propose before committing.** Never run `git commit` without first showing the user exactly what will be committed and getting consent for that specific change.
- **Consent is per-batch.** Permission to commit one set of changes is not permission to commit anything else. Each independent batch of work needs its own explicit go-ahead. Do not infer broader consent from a narrow approval.
- **Never commit unprompted.** Don't commit on your own initiative. Commit only when the user asks you to, or after they've consented to a specific proposed commit.
- **Prefer atomic commits.** Even when many changes are in flight at once, each commit should be one coherent, independently reviewable change. Always consider whether the current changes can be split into separate independent commits before proposing.

## Workflow

1. **Inspect the current state.** Before proposing anything, see what's actually there:
   - `git status` — staged, unstaged, and untracked files.
   - `git diff` — unstaged changes.
   - `git diff --staged` — already-staged changes.
   - `git log --oneline -10` — recent commit style and message conventions for this repo.

2. **Group changes into logical commits.** Partition the working-tree changes into one or more independent, atomic commits. A good commit does one thing: a feature, a fix, a refactor, a doc update. Changes that are unrelated belong in separate commits.

3. **Consider splitting before proposing.** Before settling on a plan, ask whether each proposed commit can itself be split further — including by partial staging (`git add -p`, `git add <path>`) or by selectively reverting/unstaging parts of the working tree. Prefer more, smaller, coherent commits over fewer mixed ones.

4. **Stage and verify CI.** For each batch, in order:
   - **Stage atomically** — exactly what this commit will contain, no more. Use `git add -p` / `git add <path>` for partial staging; avoid `git add -A` or `git add .` unless you intend to commit everything in the tree. Leave unrelated changes unstaged for their own commits.
   - **Verify CI** — run the repo's check commands against the staged content (see *Verify CI passes before committing*). If checks fail, fix and re-verify before proposing — don't propose a batch you know will fail CI.

5. **Propose the plan.** Present the commit plan before committing anything:
   - The list of commits, in the order you'll make them.
   - For each: the scope (which files/hunks), a draft commit message, the staging approach, and **CI verification status** (passed / couldn't verify, with what was run).
   - If you'd recommend splitting, say so explicitly and show the split.

6. **Get per-batch consent.** Wait for the user to approve a specific commit before committing it. If the user approves only part of the plan, commit only that part. Approval of commit N is not approval of commit N+1 — re-confirm, or rely only on the scope of consent they actually gave.

7. **Commit.** Run `git commit` with the approved message. Show the resulting commit (`git show --stat HEAD` or similar).

8. **Repeat for the next batch.** Return to step 1 for the remaining changes; do not assume earlier consent carries over.

## Consent in detail

- "Commit this" means *this* set of changes — not everything in the working tree.
- If the user says "commit the fix" and the working tree also contains unrelated WIP, commit only the fix. Propose the WIP separately, or leave it alone.
- If the user approved a plan of three commits, you may proceed through the three *as described*; if you discover the split needs to change, stop and re-propose.
- A "yes" to a proposed commit message is consent to commit that specific staged content with that message — not a standing OK to commit the rest of the tree.

## Verify CI passes before committing

Before committing a batch, confirm the end result will pass CI — using whatever instructions the repo provides. The goal is: **if you commit this now, CI goes green.** Find and follow the repo's own check instructions; don't invent commands.

### Finding CI instructions

Look in this order; use the first that applies:
1. **CI config** — `.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`, `.circleci/config.yml`, `bitbucket-pipelines.yml`. Read the `on:`/`push:`/`pull_request:` triggers and the step list to see exactly what CI runs. Run the same commands locally.
2. **Repo docs** — `CONTRIBUTING.md`, `README.md`, `DEVELOPMENT.md`, `docs/development.md`, or a `Makefile`/`justfile`/`package.json` scripts section. Search for words like "test", "lint", "check", "ci", "verify".
3. **Convention** — if nothing is documented, ask the user how they run checks for this repo. Don't guess.

Common forms: `make ci` / `make test`, `just ci`, `cargo test` (+ `cargo fmt --check`, `cargo clippy -- -D warnings`), `npm test` / `npm run lint` / `pnpm test`, `pytest`, `tox`, `pre-commit run --all-files`.

### Running checks against the right state

- Run checks against **the exact content that will be committed** — i.e. what you've staged for this batch, not the whole working tree. Easiest: stage first (step 6), then run the checks. If checks need a clean tree (no unstaged WIP), use `git stash -k` to temporarily set aside unstaged changes, run the checks, then `git stash pop`.
- Run checks before you propose the commit, and again if the staged content changes.
- If a check is slow, tell the user how long it's taking rather than skipping it silently.

### When checks fail

- Do not commit a batch you know will fail CI. Fix the issue, or split the batch so the failing part is excluded, or tell the user you can't verify and let them decide.
- If a check is genuinely impossible to run locally (needs secrets, special hardware, a remote service), say so explicitly and note it in the commit proposal — don't silently skip it.
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

Follow the repo's existing convention (check `git log --oneline`). Default to a concise imperative summary line (`Add …`, `Fix …`, `Refactor …`) under ~72 chars, optionally followed by a blank line and a body explaining *why*, not *what*. Reference issues with `#NN` only when genuinely related.

**Closing issues:** When a commit resolves an issue, put `Closes #N` in the commit **body** (the description), never in the summary heading. The heading should describe the change itself, not the issue-closure bookkeeping. For example:

```
Fix off-by-one in token refresh window

The expiry check compared against the wrong bound, causing premature
refresh under load.

Closes #142
```

## Don't

- Don't commit before proposing.
- Don't commit a batch you haven't verified against CI (or, if it's unverifiable locally, without telling the user).
- Don't let one consent cover unrelated commits.
- Don't bundle unrelated changes to save a step.
- Don't use `git add -A` to commit everything when only part of the tree is approved.
- Don't amend or rewrite already-pushed history without explicit instruction.
