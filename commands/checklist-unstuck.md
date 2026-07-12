---
description: Clear STUCK, flip the [!] step to either pending or in-progress.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-unstuck.sh" (--pending|--in-progress) <issue-dir>`.
Forward all arguments verbatim.
