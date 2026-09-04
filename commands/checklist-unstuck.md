---
description: Clear STUCK, flip the [!] step to either pending or in-progress.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "(--pending|--in-progress) <issue-dir>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-unstuck.sh" (--pending|--in-progress) <issue-dir>`.
Forward all arguments verbatim.

Shares `/devagent:unstuck`'s row-selection rule (the row carrying `[!]` in the
active revision block, else the first in the file — located by line, #587) and
differs only in taking an explicit `<issue-dir>` rather than a project.
