---
description: Reactivate a parked issue, flipping [P] back to [~]
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project> <issue-id>"
---

# /devagent:resume

**Usage:** `/devagent:resume <project> <issue-id>`

Reactivates a previously parked issue: flips its `[P]` step back to `[~]`,
removes it from the `[parked]` table, and promotes it to `active_issue`.

The row that actually carries `[P]` is the one flipped — the active revision
block's if one is there, otherwise the first in the file (#587; closeout step
numbers are reused across revision blocks, so the row is located by LINE, never
by number).

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), resume refuses: the issue stays parked until its question is answered. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`).
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh" $ARGUMENTS
```
