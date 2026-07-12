---
description: "Step 20: restore tree, commit devdoc, clear active_issue."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [issue-dir]"
---

# /devagent:cleanup

Invokes `scripts/cleanup.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

## Precondition (#242, generalizes #231)

`cleanup.sh` refuses to complete while ANY closeout step — `updatewbs`,
`impact`, or `lessonslearned` (each resolved by name) — is in a non-terminal
glyph (`[ ]`, `[~]`, `[!]`, `[?]`, `[P]`). The die names every offender at once.
Finish each step, or mark it `[-]` (skip) if genuinely empty — the per-step
skip is the escape hatch and stays auditable in the checklist.
`lessonslearned` is the highest-stakes gate (producer of the `[actionable]` →
`/devagent:reap` pipeline; an out-of-order close silently drops follow-ups);
updatewbs/impact are recoverable bookkeeping, but they are exactly the steps
skipped when "the code is merged, I'm done" (Issue-78/79/80). Steps absent
from the issue's checklist are not gated (research/docs-only templates).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" $ARGUMENTS`
