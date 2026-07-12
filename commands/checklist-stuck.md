---
description: Mark the current step stuck and write a STUCK file with a reason.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<issue-dir> <reason...>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" <issue-dir> <reason...>`. Forward all
arguments verbatim.
