---
description: Step 11: run static analysis then sanitizers against changed-line scope.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:analyze

Invokes `scripts/analyze.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash {{plugin_root}}/scripts/analyze.sh $ARGUMENTS`
