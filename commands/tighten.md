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
