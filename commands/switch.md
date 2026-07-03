---
description: Park current issue and resume a different one in one step
allowed-tools: Bash
argument-hint: "<project> <parked-issue>"
---

# /devagent:switch

**Usage:** `/devagent:switch <project> <parked-issue>`

Parks the currently active issue and resumes `issue-id` in a single
operation. Equivalent to `/devagent:park` followed by `/devagent:resume`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/switch.sh" $ARGUMENTS
```
