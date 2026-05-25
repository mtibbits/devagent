---
description: Extract reusable lessons from a completed issue. Invokes core-lessons-learned skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:lessonslearned

Step 19 of the 21-step devAgent workflow. Invokes the
`core-lessons-learned` skill to write `<issue-dir>/lessonsLearned.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify checklist log has > 2 entries (otherwise nothing to learn from).
3. Invoke `core-lessons-learned`. The skill calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- Fewer than 2 log entries.
- lessonsLearned.md already exists with content (overwrite? append? abort?).

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
