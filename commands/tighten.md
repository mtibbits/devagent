---
description: Final review pass on the active issue's pruned plan. Invokes core-tighten skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:tighten

Step 5 of the 21-step devAgent workflow. Invokes the `core-tighten`
skill for the last pre-implementation review of `imPlan.md`: task
ordering, dependencies, absolute file paths, per-task test plan,
Definition of done.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan-potentialFutureEnhancements.md` exists (proves
   prune ran).
3. Invoke `core-tighten` with `$ISSUE_DIR` and `$NOTE`.
4. The skill rewrites `imPlan.md` and logs via
   `scripts/checklist-log.sh`.

## Halt and ask if

- Prune step did not produce `imPlan-potentialFutureEnhancements.md`
  (the empty file is fine; missing file is not).
- Plan has a dependency cycle.

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
