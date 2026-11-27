---
description: Park current issue and resume a different one in one step
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project> <parked-issue>"
---

# /devagent:switch

**Usage:** `/devagent:switch <project> <parked-issue>`

Parks the currently active issue and resumes `issue-id` in a single
operation. Equivalent to `/devagent:park` followed by `/devagent:resume`.

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), switch refuses that target, before the current issue is parked, so a refused
switch parks nothing. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`).
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/switch.sh" $ARGUMENTS
```
