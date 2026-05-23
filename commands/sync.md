---
description: Async merge detection: fires on_merge for shipped issues that merged outside this session.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:sync

Invokes `scripts/sync.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash {{plugin_root}}/scripts/sync.sh $ARGUMENTS`
