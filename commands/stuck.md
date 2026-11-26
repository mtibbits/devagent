---
description: Mark the current step stuck and write a STUCK file
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: '<project> "<reason>"'
---

# /devagent:stuck

**Usage:** `/devagent:stuck <project> "<reason>"`

Marks current step `[!]` and writes `<issue-dir>/STUCK` per spec §5.3.
Halts `next` until cleared via `/devagent:unstuck`.

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), stuck refuses before it marks any row, so the open question is never
overwritten. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`). When the issue has a `questions/` directory, the check and the `STUCK` write run under the issue's question lock, the lock a hold takes while it creates `STUCK`; if the lock is still held after its wait (about 10 s, `hold: lock busy: …`), the check runs without it, so a real stop is never lost.
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stuck.sh" $ARGUMENTS
```
