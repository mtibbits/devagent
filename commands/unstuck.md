---
description: Clear the STUCK file and resume the previously-stuck step
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project> [--pending]"
---

# /devagent:unstuck

**Usage:** `/devagent:unstuck <project> [--pending]`

Removes STUCK file and flips `[!]` back to `[~]` (default) or `[ ]`
(with `--pending`). Spec §5.3.

The row that actually carries `[!]` is the one flipped — the active revision
block's if one is there, otherwise the first in the file (#587; closeout step
numbers are reused across revision blocks, so the row is located by LINE, never
by number) — and STUCK is removed only after that row has taken the new glyph.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unstuck.sh" $ARGUMENTS
```
