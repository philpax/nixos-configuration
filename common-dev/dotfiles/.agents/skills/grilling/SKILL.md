---
description: Use when the user wants to stress-test a plan, decision, or idea, or asks to be grilled about it.
---

# Grilling

1. **Map decisions.** Interview the user until both parties reach a shared understanding. Map the decisions as a design tree, where each decision has branches for the decisions that depend on it.

2. **Ask a round.** Identify the frontier: every decision whose prerequisites are settled. Ask all questions on the frontier in one round, numbered, with a recommended answer for each. Word each question so that a yes accepts the recommendation. Wait for the user's answers before the next round. Questions that depend on another question in the same round belong in a later round.

   Format each question as follows, separating questions with a horizontal rule:

   ```
   ❓ **Q1** - **<question title>**: <question body, including choices where useful>

   ➡️ <recommended answer>
   ```

3. **Investigate facts.** Find facts from the environment instead of asking the user for them. Dispatch a subagent when a frontier question needs a fact from the filesystem, tools, or other sources. A running investigation is an unsettled prerequisite: defer dependent questions, but ask the rest of the frontier without waiting. Put decisions to the user and wait for their answers.

4. **Repeat.** Recompute the frontier after each round. Settled decisions unblock dependent questions. Continue until every branch has been visited and no decisions remain silently assumed.

5. **Confirm.** Do not act on the result until the user confirms that both parties have reached a shared understanding.
