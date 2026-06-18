---
description: "Step 11: run static analysis then sanitizers against changed-line scope."
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:analyze

Invokes `scripts/analyze.sh` with the parsed arguments per spec §6.1.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.sh" $ARGUMENTS`
