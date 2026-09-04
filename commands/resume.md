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

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh" $ARGUMENTS
```
