---
description: Start a new revision pass; appends "## Revision N" to checklist and chains to /devagent:next
argument-hint: "[project] [issue] [--no-chain] [--retier <tier>]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

Run the revise script and report the result.

````bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/revise.sh" $ARGUMENTS
````

Then:
- If the script prints a line starting with `CHAIN: `, treat the remainder as the next slash command to invoke. Per spec §7, the same `--auto` semantics that govern `/devagent:next` apply transitively here: if the operator passed `--auto` upstream, continue chaining; otherwise pause and ask.
- If the script exited non-zero because `revisions/r<N>/comments.md` is missing, tell the user to run `/devagent:comments` first.
- The next step on the new revision is `draft` (step 1). The `draft` skill reads `pending_comments_file` from per-project state and includes those comments as user-intent context in the new plan.

## `--retier <tier>` — tier escalation valve (#537)

`revise.sh --retier <tier> [project] [issue]` promotes a misclassified
issue to a different workflow tier (the usual case: a oneshot that turned
out to produce a repo diff → `--retier standard`). It is a REVISION, not an
edit-in-place: it appends a `## Revision N` block carrying the new tier's
checklist rows (excluding row 0 — a pending `0. pull` would re-point
next.sh at pull), updates the `Template:` header, resets the step pointer
in the same issue-keyed state transaction (#414 shape), and logs a
discriminating `retier: <old> → <new>` entry. Never destructive: the log
and all prior revision blocks are preserved. Unlike an MR-feedback revise
it does NOT require `revisions/r<N>/comments.md` and does not set
`pending_comments_file`. The tier is validated against the same allowlist
pull.sh uses (legal names: the spec §6.3 tier table).

Known limitation (pre-existing for every non-standard-template issue, not
introduced by retier): a subsequent GENUINE revise appends
`revision_block.md`, which is standard-shaped regardless of the
`Template:` header — after `--retier <non-standard>`, that next
MR-feedback block reintroduces standard-only rows. Tier-shaped revision
blocks are a recorded future enhancement.
