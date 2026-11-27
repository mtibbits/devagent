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

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), checklist-unstuck refuses, even when an older revision block still carries a
`[!]` row. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`).
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.
