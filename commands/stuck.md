---
description: Mark the current step stuck and write a STUCK file
---

# /devagent:stuck

**Usage:** `/devagent:stuck "<reason>"`

Marks current step `[!]` and writes `<issue-dir>/STUCK` per spec §5.3.
Halts `next` until cleared via `/devagent:unstuck`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stuck.sh" $ARGUMENTS
```
