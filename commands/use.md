---
description: Deliberately switch the active project (the one arg-driven pointer writer)
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<project>"
disable-model-invocation: true
---

# /devagent:use

**Usage:** `/devagent:use <project>`

Sets the global active-project pointer (`~/.claude/devagent/state/_active.toml`)
to `<project>`, then prints the resolved state (project, active issue, current
step). This is the deliberate, arg-driven way to switch projects on a
multi-project install — since #282 the pointer is otherwise written only by
pointer/fallback-resolved `/devagent:next` runs, so its value would freeze. The
`_active.toml` hand-edit and the per-session `DEVAGENT_ACTIVE_PROJECT` env pin
remain as the fallback / per-session alternatives (see "Concurrent sessions" in
`commands/next.md`).

An unknown project is rejected (the pointer is left unchanged). Does **not**
execute a workflow step — invites the operator to run `/devagent:next`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/use.sh" <project>
```
