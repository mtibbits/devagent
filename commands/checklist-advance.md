---
description: Mark the current checklist step done and report the next step.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<issue-dir>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-advance.sh" <issue-dir>`. Forward all arguments
verbatim. Surface stderr to the user.
