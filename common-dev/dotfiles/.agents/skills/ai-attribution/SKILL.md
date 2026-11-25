---
description: Use when drafting outward-facing prose, including commit messages, GitHub issues, and pull request descriptions. Defines the attribution footer that names the drafting model. Loaded by the committing, github-issue, github-issue-simple, and pr-propose skills.
---

# Model attribution footer

Outward-facing text names the model that drafted it. The footer goes into the draft shown for approval, so the user can strike it.

## Issues and pull request descriptions

The footer is the last block of the body, after `Closes #NN` when present:

```
---

_Created by `deepseek-v4.1-flash`._
```

Keep the blank line before `---`, or it renders as a setext heading underline.

## Commit messages

A trailer after any closing-issue trailer, on every commit in a series:

```
Closes #142
Model: <model-name>
```

The trailer is not a body paragraph and does not count toward the two to three.

## Naming the model

Name the model, not the provider. Take it from the session's model identity and ignore the provider field. Drop the `provider/` segment, and drop a leading wrapper prefix that repeats the provider and is not part of the model's own name.

- `umans/umans-deepseek-v4.1-flash` gives `deepseek-v4.1-flash`. `umans` is a routing wrapper.
- `deepseek/deepseek-v4.1-flash` gives `deepseek-v4.1-flash`.
- `mistral/mistral-large-2411` gives `mistral-large-2411`. The vendor prefix is part of the published name.

The test is whether the prefix is the vendor's own name for the model or a wrapper around it. Never include the provider, route, or host.

If the session states no model identity, ask which model to name.

## Opting out

Omit the footer when the user asks, or when the repository rejects attribution in `CONTRIBUTING.md`, CI, or a commit hook. Say so once when presenting the draft.
