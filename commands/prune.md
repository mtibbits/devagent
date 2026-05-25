---
description: Move deferred and off-scope items from the active issue's plan to the future-enhancements file. Invokes core-prune skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:prune

Step 4 of the 21-step devAgent workflow. Invokes the `core-prune`
skill to migrate non-load-bearing items from `imPlan.md` into
`imPlan-potentialFutureEnhancements.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists with `## Improvements` section.
3. Invoke `core-prune` with `$ISSUE_DIR` and `$NOTE`.
4. The skill modifies `imPlan.md`, writes/appends
   `imPlan-potentialFutureEnhancements.md`, and logs via
   `scripts/checklist-log.sh`.

## Halt and ask if

- `## Improvements` section missing (run improve first).
- After pruning, no tasks remain.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
