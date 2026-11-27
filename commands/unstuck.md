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

## A held issue (#963)

While the issue's `STUCK` is an operator question (`Kind: question`, written
by a hold, #962), unstuck refuses, even when an older revision block still carries a `[!]` row:
a question is cleared by answering it, not by unsticking. It changes nothing, prints the `STUCK` path and its
answer line on stderr, and exits `operator-question` (the code is in
`scripts/lib/refusals.sh`).
On that exit, stop: the issue is held. Report the `STUCK` path and the answer line to the operator; do not retry, unstick, resume or re-pull the issue. Any other `STUCK` is handled as before.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unstuck.sh" $ARGUMENTS
```
