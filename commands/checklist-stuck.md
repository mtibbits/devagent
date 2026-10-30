---
description: Mark the current step stuck and write a STUCK file with a reason.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--step <N> <name> | --name <step-name>] <issue-dir> <reason...>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" [--step <N> <name> | --name <step-name>] <issue-dir> <reason...>`. Forward all
arguments verbatim.
