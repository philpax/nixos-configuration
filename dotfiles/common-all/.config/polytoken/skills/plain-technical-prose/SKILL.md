---
description: Use when writing or revising any prose — documentation, design specs, READMEs, commit messages, PR descriptions, issue bodies, code comments. Triggers on phrases like "less Claudish", "make this drier", "plain technical register", "too much Markdown", "de-emphasise this", "rewrite the docs", or when drafting a document that should read as a plain specification.
---

# Plain technical prose

Prose written to this style reads as a specification rather than as persuasion. It states what is true, why, and at what cost, without typographic emphasis or rhetorical construction. Apply it to documentation, design specs, READMEs, commit messages, PR descriptions, issue bodies, and code comments.

The reference for this style is ASD-STE100. Apply its discipline: short sentences, active voice, one topic per sentence, present tense, and controlled terminology. Do not claim conformance, and do not apply its approved-word list, which mangles domain terms such as `dmabuf`, `composite`, and `swapchain`.

## Rules

Sentences. One idea per sentence. Prefer short declarative sentences. Use active voice unless the actor is genuinely unknown or irrelevant. Use present tense for behaviour and past tense only for history.

Person. Third person throughout. Name the actor: the user, the compositor, the host desktop, the caller. Do not use "you", "your", "we", "our", or "us". "our fork" becomes "the fork"; "you can't read your editor with the headset on" becomes "the editor is not readable with the headset on".

Terminology. Choose one term per concept and keep it. Synonym variation for stylistic relief obscures whether two names mean the same thing. If a document uses both "Rust" and "the native layer", decide which one each context needs and apply it consistently.

Figures of speech. No metaphor, idiom, rhetorical question, or aside. No sentence fragments used for effect. No punchlines, no understatement, no self-deprecation.

Punctuation. No em-dash asides. Split the aside into its own sentence, or replace the dash with a colon when the second clause expands the first. Parentheses are acceptable for short references and qualifications.

Markdown. Keep headings, tables, code blocks, inline code, links, and lists that enumerate a real set. Remove bold, italics, and bolded lead-in labels. A bolded lead-in becomes an ordinary sentence opener: "**Import is zero-copy and per-buffer.** Wayland clients cycle..." becomes "Import is zero-copy and per-buffer. Wayland clients cycle...". Remove any formatting whose purpose is emphasis rather than structure. Do not hard-wrap lines.

One exception applies to agent instruction files, meaning `SKILL.md` and similar. Those keep bolded lead-in labels on numbered workflow steps, where the label names the step and acts as structure. The register rules still apply to the prose that follows each label.

Headings. Name the subject, not the reading experience. "How a click reaches an application" becomes "Path of an input event". "Two details that bite if ignored" becomes "Two details matter if ignored", or the sentence is dropped and the list stands alone.

Emphasis. Emphasis carried by typography or by a catchy line is carried by plain prose instead. State the fact and its consequence in order. "Dead handles go inert. Ugly. Less ugly than a race taking down your desktop." becomes "Dead handles go inert rather than raising errors. This is a compromise, made because it is less disruptive than a race condition taking down the session."

Judgements. Keep every judgement, and state it as a claim with a reason. Drop the attitude, not the position. "which is a debugging surface we don't need" becomes "would add a debugging surface with no offsetting benefit". "exactly backwards" becomes "counterproductive".

Characters. Use ASCII where a Unicode character adds nothing: `1920x1080`, not `1920×1080`; `2 to 4 buffers`, not `2–4 buffers`. Keep Unicode in proper nouns and in code.

## Writing new prose

Write to these rules from the first draft. Do not draft in a livelier register with the intention of flattening it later; the flattening pass loses content.

The register is the delivery, not the content. Reasoning, caveats, numbers, trade-offs, and cross-references belong in a plain-register document exactly as much as in any other. A dry document is not a shorter document.

## Rewriting existing prose

1. Read the whole document before changing anything. The rewrite depends on knowing which terms the document has committed to and which cross-references must survive.
2. Rewrite section by section. For each paragraph, identify what it asserts, then restate the assertions in the target register. Do not paraphrase sentence by sentence; that preserves the original's rhetorical shape.
3. Preserve content exactly. Every decision, rationale, caveat, number, file reference, link, and anchor target stays. Anchors are load-bearing: renaming a heading breaks inbound links, so update every link to a heading that is renamed.
4. Check the line count and the file list after the rewrite. A content-preserving rewrite lands close to its original length. A large drop means content was lost, not compressed.
5. For a multi-document rewrite, do all documents in one pass so terminology stays consistent across them, and state in the commit message that content is unchanged.

## Interaction with other skills

This skill governs register. It does not override document structure defined elsewhere. When drafting a GitHub issue, follow the `github-issue` structure and write its prose to these rules. When writing a commit message, follow the repository's commit conventions and write the body to these rules.

Two carve-outs apply to code comments. Comments stay short, and a comment that is already a single plain sentence needs no change. Do not rewrite comments in a file that the task did not otherwise touch.

## Verification

Before presenting a rewrite, check the result for: remaining bold or italic markers used for emphasis; occurrences of "you", "your", "we", "our"; em-dashes; and headings that describe the reader's experience rather than the subject. Each of these is a fast grep and each catches the common failure.
