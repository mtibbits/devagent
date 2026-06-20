---
description: "Step 20: restore tree, commit devdoc, clear active_issue."
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:cleanup

Invokes `scripts/cleanup.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

## Precondition (#231)

`cleanup.sh` refuses to complete while the issue's `lessonslearned` step
(resolved by name) is in a non-terminal glyph (`[ ]`, `[~]`, `[!]`, `[?]`).
Mark step 19 `[x]` (run `/devagent:lessonslearned`) or `[-]` (genuinely
nothing to learn) first — `lessonslearned` is the producer of the
`[actionable]` → `/devagent:reap` pipeline, so an out-of-order close silently
drops follow-ups. A checklist with no `lessonslearned` step is not gated.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" $ARGUMENTS`
