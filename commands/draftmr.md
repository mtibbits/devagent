---
description: Draft the MR body for the active issue. Invokes core-draft-mr skill.
allowed-tools: Bash, Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draftmr

Step 12 of the 22-step devAgent workflow. Invokes the
`core-draft-mr` skill to fill the resolved `mr_template.md` (§12 registry: project paths → devdoc → plugin default) from the
issue's artifacts and write `<issue-dir>/mr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify analyze step completed (`<issue-dir>/analysis/` exists) — UNLESS the
   issue's `checklist.md` does not contain the analyze step (step 11), as in the
   docs-only checklist, OR step 11 is marked `[-]` (self-skipped: the project
   sets `analyze = "none"`, #55 — the skip reason is in the checklist log). A
   prerequisite whose producing step is absent from the issue's checklist or
   legitimately self-skipped is **N/A**: skip this check and proceed, do not
   halt.
3. Verify actualWork.md exists.
4. Invoke `core-draft-mr`. The skill calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- analyze step did not run (no analysis/ dir) **and** the analyze step (11) is
  present in the issue's checklist **and** not marked `[-]`. If the checklist
  omits analyze (docs-only) or step 11 self-skipped (`analyze = "none"`, #55),
  analyze is N/A — do not halt.
- actualWork.md missing.
- mr.md already exists with content (overwrite? revise? abort?).

## Skipping policy

Never auto-skip.

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
