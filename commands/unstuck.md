---
description: Clear the STUCK file and resume the previously-stuck step
---

# /devagent:unstuck

**Usage:** `/devagent:unstuck [project] [--pending]`

Removes STUCK file and flips `[!]` back to `[~]` (default) or `[ ]`
(with `--pending`). Spec §5.3.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unstuck.sh" "$@"
```
