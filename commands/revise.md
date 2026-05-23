---
description: Start a new revision pass; appends "## Revision N" to checklist and chains to /devagent:next
argument-hint: "[project] [issue] [--no-chain]"
allowed-tools: Bash
---

Run the revise script and report the result.

````bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/revise.sh" $ARGUMENTS
````

Then:
- If the script prints a line starting with `CHAIN: `, treat the remainder as the next slash command to invoke. Per spec §7, the same `--auto` semantics that govern `/devagent:next` apply transitively here: if the operator passed `--auto` upstream, continue chaining; otherwise pause and ask.
- If the script exited non-zero because `revisions/r<N>/comments.md` is missing, tell the user to run `/devagent:comments` first.
- The next step on the new revision is `draft` (step 1). The `draft` skill reads `pending_comments_file` from per-project state and includes those comments as user-intent context in the new plan.
