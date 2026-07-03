---
description: Reactivate a parked issue, flipping [P] back to [~]
allowed-tools: Bash
argument-hint: "<project> <issue-id>"
---

# /devagent:resume

**Usage:** `/devagent:resume <project> <issue-id>`

Reactivates a previously parked issue: flips its `[P]` step back to `[~]`,
removes it from the `[parked]` table, and promotes it to `active_issue`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh" $ARGUMENTS
```
