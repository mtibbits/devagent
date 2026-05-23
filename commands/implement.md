---
description: Execute the active issue's plan task-by-task. Wraps superpowers:executing-plans.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:implement

Step 7 of the 21-step devAgent workflow. Invokes the upstream
`superpowers:executing-plans` skill against `<issue-dir>/imPlan.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify branch step has completed (state file's `branch` field is
   set and the working tree is on that branch). If not, halt.
3. Verify `imPlan.md` has a `## Definition of done` section (proves
   tighten ran).
4. Invoke `superpowers:executing-plans` with `$ISSUE_DIR/imPlan.md`
   as the plan path. Pass `$NOTE` as additional context the executor
   should consider (e.g., "skip task 4 — already merged upstream").
5. Implementation happens task-by-task per the wrapped skill's
   conventions. Each task gets its own commit per executing-plans
   defaults.
6. On full completion, append a single summary log entry:

```bash
scripts/checklist-log.sh "$ISSUE_DIR" implement \
  "Plan implemented: N tasks done, F files changed, all tests pass; note: $NOTE"
```

## Halt and ask if

- Working tree is not on the issue's branch.
- `imPlan.md` lacks Definition of done.
- A task fails halfway through — surface the failure and let the
  operator decide whether to mark the step `[!]` stuck (via
  `/devagent:stuck`) or retry.

## Skipping policy

Never auto-skip individual tasks; the wrapped skill's task-level
prompting handles that. At the step level, never auto-skip implement
itself — without code change the rest of the pipeline is meaningless.
