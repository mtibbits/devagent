---
description: Show active issue, current/next step, parked issues, and STUCK status
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project>"
---

# /devagent:where

**Usage:** `/devagent:where <project>`

Reports the active issue, the current step, the next actionable step,
any STUCK file contents, and any parked issues for the project. Does
**not** execute the next step — invites the operator to run
`/devagent:next` instead.

Implements spec §6.5.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/where.sh" <project>
```
