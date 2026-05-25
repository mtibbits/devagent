---
description: Record actual work versus the plan for the active issue. Invokes core-document-actual-work skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:document

Step 9 of the 21-step devAgent workflow. Invokes the
`core-document-actual-work` skill to write
`<issue-dir>/actualWork.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file has a `baseline_sha` (needed to diff actual
   against plan). If absent, halt — operator must run branch first.
3. Invoke `core-document-actual-work` with `$ISSUE_DIR` and
   `$NOTE`.
4. The skill writes actualWork.md and calls `scripts/checklist-log.sh`.

## Halt and ask if

- State file lacks `baseline_sha`.
- imPlan.md lacks `## Definition of done` section.

## Skipping policy

Never auto-skip; documenting deviations is the entire value of this
step.

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

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first line in the issue's checklist.md
that starts with `- [ ]` -- read that, take the verb after the
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
