---
description: Park the active issue (or a named issue), marking it [P]
allowed-tools: Bash
---

# /devagent:park

**Usage:** `/devagent:park [issue-id]`

Parks the active issue (or `issue-id` if given), marking its current step
`[P]` and recording it in the `[parked]` table. Clears `active_issue` from
state when the parked issue was the active one.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/park.sh" $ARGUMENTS
```
