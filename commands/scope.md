---
description: Run six-question scope evaluation on the active issue's plan. Invokes core-scope skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:scope

Step 2 of the 21-step devAgent workflow. Invokes the `core-scope`
skill to walk through six structured questions and append a
`## Scope evaluation` section to `<issue-dir>/imPlan.md`.

## Argument parsing

Identical to `/devagent:draft`. See `commands/draft.md` for the full
spec §6.1 grammar. In one sentence: optional `project`, optional
`Issue[-Fork]-N`, the rest is `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `<issue-dir>/imPlan.md` exists. If not, halt: operator must
   run `/devagent:draft` first.
3. Invoke the `core-scope` skill with `$ISSUE_DIR=<issue-dir>`
   and `$NOTE` as user intent.
4. The skill appends `## Scope evaluation` to `imPlan.md`.
5. The skill itself appends the log entry via
   `scripts/checklist-log.sh`.

## Halt and ask if

- `imPlan.md` is missing (run draft first).
- A `## Scope evaluation` section already exists (overwrite? new
  sub-section? abort?).

## Skipping policy

Never auto-skip. If the issue is a trivial typo and the six questions
don't apply, surface the skip request to the operator rather than
silently advancing.

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
