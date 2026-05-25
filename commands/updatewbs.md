---
description: Alias for `/devagent:wbs update` (workflow step 17)
allowed-tools: Bash
---

Run `scripts/wbs.sh update "$@"` with the user's arguments.

This is the workflow step-17 entrypoint. Identical behavior to
`/devagent:wbs update`; exists as a separate command so the 21-step
workflow chaining (`--auto`, `--through`) and skill mapping can
reference a single verb.

## Completion handoff

After the skill completes:

- Mark the step `[x]` (or `[-]` skipped) and log via
  `scripts/checklist-log.sh`.
- **STOP.** Do not invoke any other `/devagent:*` command unless this
  invocation arrived under a `/devagent:next --auto` or `--through`
  chain — recognizable because the preceding turn's output contained a
  `CHAIN: /devagent:next ...` line. In that case, invoke that
  CHAIN: command verbatim to continue.
- If the operator typed `/devagent:<name>` directly (no CHAIN: line),
  do NOT advance. The operator's last explicit instruction is the
  authoritative scope. Wait for the next operator turn even if your
  internal todo list still has follow-on steps queued.
