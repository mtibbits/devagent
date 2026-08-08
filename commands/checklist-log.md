---
description: Append a timestamped entry to the checklist log.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<issue-dir> <step-name> <message...>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" <issue-dir> <step-name> <message...>`.
Forward all arguments verbatim.
