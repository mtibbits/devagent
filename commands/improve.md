---
description: Surface latent bugs, side effects, ambiguities in the active issue's plan. Invokes core-improve skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:improve

Step 3 of the 21-step devAgent workflow. Invokes the `core-improve`
skill to read `<issue-dir>/imPlan.md` and append an `## Improvements`
section flagging concrete defects.

## Argument parsing

Per `commands/draft.md`. In short: optional `project`, optional issue
dir, remainder = `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists AND contains a `## Scope evaluation`
   section. If not, halt and tell the operator to run scope first.
3. Invoke `core-improve` with `$ISSUE_DIR` and `$NOTE`.
4. The skill appends `## Improvements` and calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- Plan lacks `## Scope evaluation`.
- Plan already has an `## Improvements` section (overwrite? append
  sub-section? abort?).

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.

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
