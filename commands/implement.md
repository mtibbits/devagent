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

## Do NOT commit yet

You will be tempted to run `git commit` after this step finishes —
'the work is done, capture it!' — but this is not the commit
step. The 21-step workflow defers commit until AFTER static analysis
(step 11: `/devagent:analyze`) so the commit captures verified work
and you do not need to amend.

If your work feels at risk in the working tree, you may:
- `git stash` and unstash before the commit step
- write an actualWork.md note describing what you built so it can be
  reproduced if lost

But do NOT `git commit`. The commit step (10) follows analyze (11)
in the checklist order intentionally. If you commit early, the
commit step has nothing to commit and the analyze step finds issues
you must amend in, polluting your commit history.

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" <N> x
```

`<N>` is this step's number on the issue's checklist; use `-` instead of
`x` if the step was skipped. Then run the Logging command above (if this
skill/command defines one).

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first step in the issue's checklist.md not
marked `[x]` or `[-]` -- read that line, take the verb after the
step number, and substitute it into the question.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then do NOT ask the question -- instead invoke that exact CHAIN:
command verbatim to continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO ask the question and wait for the
operator's answer. Do not advance even if your internal TODO list
still has steps after this one -- the operator's last explicit
instruction is the authoritative scope.
