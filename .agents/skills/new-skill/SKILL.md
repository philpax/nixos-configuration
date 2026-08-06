---
description: Use when creating a new agent skill. Discovers the current skill targets (the dotfiles layer dirs, defaulting to common-all, plus the local .agents/skills store), asks which one the skill should live in, then scaffolds SKILL.md in the house format and verifies it will be picked up.
---

# Creating a new skill

## What this is for

This repo keeps agent skills in two kinds of places, and a new skill needs to land in the right one: the per-layer Polytoken skills dirs (which sync.py symlinks into Claude Code on every machine that includes the layer) or this repo's local `.agents/skills` store (Claude Code project skills, via the `.claude/skills` → `.agents/skills` symlink). The choice changes who gets the skill, so it's a question, not a guess.

## Workflow

1. **Understand the ask.** What should the skill do, and when should it trigger? Propose a kebab-case `<name>` for the skill folder from the user's description, plus a one-line description containing the trigger phrases. If the request doesn't give you enough to name it, say what you'll call it and let the user correct you.

2. **Discover, then ask which target.** The target list changes as machines and layers come and go, so don't rely on a remembered list — enumerate the current targets at runtime:
   - List the subdirectories of `dotfiles/` (`ls -d dotfiles/*/` or equivalent). Each one is a skill target: skills live at `dotfiles/<layer>/.config/polytoken/skills/<name>/SKILL.md`. sync.py scans every layer's `polytoken/skills` subdirectory, so any existing folder is a valid target with no further wiring. Only list what's actually there — don't invent machines or layers that don't have a `dotfiles/` folder.
   - Add the one fixed target: `.agents/skills/<name>/SKILL.md` (this repo only — Claude Code project skills via the `.claude/skills` → `.agents/skills` symlink).
   - Default to `common-all` when it's among the discovered folders. Present all targets: in Polytoken, use `ask_user_question` with common-all as the recommended selectable option and `.agents/skills` as the second, free text for anything else; in Claude Code, present the list plainly and wait for the answer. If the user wants a target that has no `dotfiles/` folder yet, offer to create it as part of the scaffold.
   - If the repo isn't this one (no `dotfiles/` tree), say so and ask where the user keeps their skills instead of guessing.

3. **Check for collisions.** If the target dir already has a `<name>/`, stop and propose a different name or ask before overwriting anything.

4. **Scaffold SKILL.md** in the house format — match the existing skills:
   - YAML frontmatter with a single `description:` line that says when to use the skill and includes likely trigger phrases.
   - A markdown body that starts with a `# Title`, then the workflow as numbered steps. If the skill creates external artifacts (issues, commits, files), spell out the consent requirements the way the `github-issue` and `committing` skills do.
   - Keep it to a single SKILL.md unless the skill genuinely needs companion files (see `dotfiles/redline/.config/polytoken/skills/llama-cpp-model-tuning/` for a multi-file example).
   - Write the body in the register the `plain-technical-prose` skill defines: short declarative sentences, third person, consistent terminology, no metaphor or catchy emphasis statements. Bolded lead-in labels on numbered workflow steps are the documented exception and are kept; the prose after each label follows the register.

5. **Write, then verify.** Write the file, re-read it, and confirm the frontmatter parses and the description reads like the other skills'. Say how it goes live: Polytoken picks up the description on reload; Claude Code reads `~/.claude/skills` on machines after `./sync.sh`, and `.claude/skills` in this repo through the symlink.

6. **Wrap up.** Show the final path, what triggers it, and remind that machine targets take effect per-machine via `./sync.sh <machine>`.