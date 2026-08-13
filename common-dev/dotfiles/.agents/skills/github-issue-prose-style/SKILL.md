---
description: The title form, body structure, and reader model for GitHub issues. Loaded by the github-issue and github-issue-simple skills, and usable directly when revising an existing issue body. Takes its register from plain-technical-prose.
---

# GitHub issue prose style

Register comes from `plain-technical-prose`, which also covers self-reference, personification, implicature, definition at first use, and describing the present state. The rules here are the ones specific to issues.

## The reader

An issue is read alone, out of order, and without the conversation that produced it. The reader holds part of the context: the author some months later, a collaborator who has not touched the subsystem, or whoever picks the issue up from a list.

A term is defined inside the issue rather than by reference to a conversation or to a document the reader may not open. Nothing is positioned against an external structure: "the second remaining extra", "the first of the four", and "as listed above" describe a list the reader does not have.

## Titles

A title for work names the change, as a verb phrase: "Cache materialised state with a high-water mark".

A title for a defect names the symptom: "Login form ignores submit on the second click".

A title of either form avoids stating the end state as a property. "Materialisation is a disposable cache" describes a system that already behaves that way, which a specification records and an issue does not ask for.

A title is one clause, with nothing appended after a dash, a colon, or a comma.

## Structure of a work issue

A work issue has three parts, in this order: current state, change, and done when.

Current state gives the behaviour today, the missing capability, or the constraint that applies. Terms used later are introduced here.

Change gives the work, stated as behaviour rather than as a task list. Where an alternative was considered and rejected, the issue names the alternative and the reason for rejecting it, so it is not proposed again.

Done when is one sentence, checkable by someone other than the author, naming the form of verification: a test, a measurement, a recorded decision, an observable behaviour.

A decision issue takes the same shape. The options, with what each costs and what each prevents, stand in place of the change, and the closing sentence names where the decision is recorded.

## Prerequisites

Name a prerequisite as work: "The blob layer is a prerequisite. It stores blobs, transfers them between devices, and governs their retention."

Record the ordering in the tracker as well. A query can read issue links, sub-issue relationships, and blocked-by relationships, and cannot read a sentence. The prose describes what the prerequisite is, and the tracker relationship identifies which issue it is.

## Verification

Check a draft for a title stating an end state rather than a change, a term used and never defined, a sentence positioned against a document or a list the reader does not have, and a "Done when" that only the author could check. The register checks in `plain-technical-prose` apply in addition.
