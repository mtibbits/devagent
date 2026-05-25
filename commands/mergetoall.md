---
description: Step 16: squash-merge the issue branch into dev/all-prs.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:mergetoall

Invokes `scripts/mergetoall.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergetoall.sh" $ARGUMENTS`
