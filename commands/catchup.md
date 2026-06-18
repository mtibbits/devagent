---
description: One-screen rehydration of an issue
allowed-tools: Bash
---

# /devagent:catchup

**Usage:** `/devagent:catchup [project] [issue]`

Synthesises issue title, current step, STUCK, head of imPlan, tail of
actualWork, last 2 comments, last 5 log entries (spec §6.5).

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/catchup.sh" $ARGUMENTS
```
