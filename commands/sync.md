---
description: Async merge detection: fires on_merge for shipped issues that merged outside this session.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:sync

Invokes `scripts/sync.sh` with the parsed arguments per spec §6.1.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" $ARGUMENTS`
