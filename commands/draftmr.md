---
description: Draft the MR body for the active issue. Invokes core-draft-mr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draftmr

Step 12 of the 21-step devAgent workflow. Invokes the
`core-draft-mr` skill to fill `${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md` from the
issue's artifacts and write `<issue-dir>/mr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify analyze step completed (`<issue-dir>/analysis/` exists).
3. Verify actualWork.md exists.
4. Invoke `core-draft-mr`. The skill calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- analyze step did not run (no analysis/ dir).
- actualWork.md missing.
- mr.md already exists with content (overwrite? revise? abort?).

## Skipping policy

Never auto-skip.

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
