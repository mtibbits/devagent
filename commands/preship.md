---
description: "Step 21: fresh-context verification that the committed branch satisfies the ACs and contains all findings, before ship. Wraps core-preship."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:preship

Step 21 of the devAgent 22-step workflow (file-ordered between redmr (14)
and ship (15); the number is unique — file order is execution authority).
Invokes the `core-preship` skill, which dispatches a fresh-context
verification subagent (model via `step-model.sh <project> 21`, else
inherit — see the skill's dispatch contract) and writes
`<issue-dir>/preship.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `mr.md` exists (draftmr ran) and the redmr artifact exists —
   UNLESS the issue's checklist does not contain step 14 (docs-only): a
   prerequisite whose producing step is absent is **N/A**, and the review
   report alone is the findings input. Do not halt on the absent step;
   DO halt when the step is present but its artifact is missing.
3. Invoke `core-preship` with `$ISSUE_DIR`, `$NOTE`, and the resolved
   project (the skill's dispatch contract needs it for step-model.sh).
4. The skill writes `preship.md` (subagent-authored under dispatch). Any
   failed verification: the skill's failure protocol marks the step `[!]`
   via `checklist-stuck.sh` — next.sh halts there; recovery is
   `/devagent:unstuck` after addressing the failures.

## Halt and ask if

- `mr.md` missing (run draftmr first).
- Step 14 present in the checklist but no `analysis/*-redmr.md` (and the
  docs-only inverse: step 13 present but no review artifact).
- State lacks `baseline_sha`/`branch` (preship cannot identify the push
  content).

## Skipping policy

Zero-diff auto-skip only, per the skill's Zero-diff section (`empty` ⇒
`[-]`; `indeterminate` never auto-skips). Never skip otherwise.

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
