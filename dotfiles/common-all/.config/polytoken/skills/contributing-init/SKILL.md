---
description: Use when initialising or re-creating a project's CONTRIBUTING.md. Composes general.md plus the applicable ecosystem templates from philpax/contributing-templates, asks about additional constraints before writing, then symlinks CLAUDE.md and AGENTS.md to the result.
---

# Initialising a CONTRIBUTING.md

## What this is for

A good CONTRIBUTING.md serves humans and agents alike. This skill creates one from the shared conventions in [philpax/contributing-templates](https://github.com/philpax/contributing-templates): `general.md` always, plus the language- and framework-specific files that actually apply to the project. It then makes the same content reachable as `CLAUDE.md` and `AGENTS.md` by symlinking them to the new file.

The templates are a starting point, not a standard. Projects amend their copies with project-specific detail, and the local copy is expected to diverge. The goal here is a solid baseline that can be refreshed later with the `contributing-update` skill.

## Workflow

1. **Investigate before deciding or asking.** You need evidence for which templates apply. Look at:
   - Language manifests: `Cargo.toml` / `Cargo.lock`, `package.json` (and its dependencies), `pyproject.toml`, `go.mod`, `CMakeLists.txt`, `*.csproj`, and so on.
   - Framework usage, not just filenames: JSX/TSX components plus a React dependency means React; a `tailwind.config.*` or `@tailwindcss/*` dependency means Tailwind; a plain TypeScript library takes neither. Don't infer a whole stack from one subdirectory name.
   - Existing guidance: `README.md`, any current `CONTRIBUTING.md`, `AGENTS.md`, `CLAUDE.md`, `docs/`. These tell you what project-specific sections to keep, port, or rewrite.
   - What already exists at `CONTRIBUTING.md`, `CLAUDE.md`, and `AGENTS.md`, and in what form (regular file, symlink, or a `@CONTRIBUTING.md` include file).

2. **Ask afterwards — only about what the codebase doesn't already answer.** Use `ask_user_question` (up to four questions in one call, each allows free text). Ask:
   - **Additional constraints** (free text, always worth asking): anything project-specific to bake in — CI commands, tooling versions, review requirements, conventions the templates don't cover. Keep it a genuine open question; don't steer it.
   - **Template set** (single select): state what you plan to use and why — e.g. "a Rust CLI, so `general.md` + `rust.md`" or "Rust daemon with a React + Tailwind frontend, so all five". Let the user add or drop files. Skip this if the manifests make the set obvious and you've already told them what you found.
   - **Existing file disposition** (only if a `CONTRIBUTING.md` or `CLAUDE.md`/`AGENTS.md` already exists): replace, merge, or back up and replace.

   Template selection rules, from the templates repo README:
   - `general.md` — language-agnostic conventions. Always.
   - `rust.md`, `typescript.md` — per language.
   - `react.md`, `tailwind.md` — per library, on top of `typescript.md`; only include one if the project actually uses it.
   - So a Rust daemon with a React + Tailwind frontend takes all five, and a Rust CLI takes two. If you need the current file list rather than assuming these five are still all there are, fetch the repo's file tree (the GitHub page or contents API) first.

3. **Fetch the templates.** Pull each needed file from `https://raw.githubusercontent.com/philpax/contributing-templates/main/<file>.md`. Read them fully before composing; don't paste blind.

4. **Compose the CONTRIBUTING.md**, in this order:
   - A short opening: `## What This Is` — two to five sentences on what the project is and its stack, for someone arriving fresh.
   - Project-specific sections from your investigation and the user's constraints: Deployment, Architecture, Development, CI, whatever the project actually has. Port anything useful from an existing CONTRIBUTING.md or README instead of dropping it.
   - The template content, appended verbatim as the baseline: `general.md` first, then language files (`rust.md`, `typescript.md`), then library files (`react.md`, `tailwind.md`).
   - Fold the user's additional constraints into the relevant sections rather than dumping them at the end.
   - Write the sections you author yourself — the opening and the project-specific ones — in the register the `plain-technical-prose` skill defines. Template content is appended verbatim and is not restyled: rewriting it would break `contributing-update`'s ability to diff the local copy against upstream.
   - A sync marker near the top, right after the opening, so `contributing-update` can find you later: `<!-- contributing-templates: files=general.md,rust.md @ <upstream-commit-or-date> -->`. Record the upstream commit SHA if you can get it, otherwise the date.

5. **Write the file.** Only after the user confirmed the plan in step 2. Handle an existing file exactly as answered in step 2: overwrite, merge, or move it to `CONTRIBUTING.md.bak` first. Project root by default, unless the repo keeps docs elsewhere or the user says otherwise.

6. **Symlink `CLAUDE.md` and `AGENTS.md` to it**, so both agent entry points read the contributing guide:
   - `ln -s CONTRIBUTING.md CLAUDE.md` and `ln -s CONTRIBUTING.md AGENTS.md` (relative symlinks in the project root).
   - If either exists as a regular file with real content, don't clobber it — ask. Reasonable options: replace with a symlink (back up first), or keep the file but set its contents to `@CONTRIBUTING.md` (Claude Code's include syntax, which serves the same purpose).
   - If symlinks aren't available (say, Windows without developer mode), fall back to the include files — the content is what matters.
   - Verify with `ls -l` / `readlink` that both resolve to `CONTRIBUTING.md`.

7. **Show the result.** Briefly: which templates went in, which project-specific sections were added, and the symlinks created. Note that `contributing-update` is the way to refresh the template-derived sections from upstream later. Don't commit unless asked; if you are asked, follow the `committing` skill.