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
