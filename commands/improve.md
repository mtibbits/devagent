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
