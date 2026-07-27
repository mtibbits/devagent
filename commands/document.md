---
description: Record actual work versus the plan for the active issue.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:document

Step 11 of the 24-step devAgent workflow. Invokes the
`core-document-actual-work` skill to write
`<issue-dir>/actualWork.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file has a `baseline_sha` (needed to diff actual
   against plan). If absent, halt — operator must run branch first —
   UNLESS the issue's ACTIVE revision block (the last `## Revision N`;
   earlier blocks may predate a #537 retier) does not contain the branch
   step (step 8), as in the research and oneshot checklists.
   A prerequisite whose producing step is absent from the issue's checklist is N/A, not a halt:
   skip this check and proceed without a diff baseline.
3. Invoke `core-document-actual-work` with `$ISSUE_DIR` and
   `$NOTE`.
4. The skill writes actualWork.md and calls `scripts/checklist-log.sh`.

## Halt and ask if

- State file lacks `baseline_sha` **and** the branch step (8) is present in the
  issue's checklist. If the checklist omits branch (research), the baseline is
  N/A — do not halt.
- imPlan.md lacks `## Definition of done` section **and** the draft step (2)
  is present in the active revision block. If the checklist omits draft
  (oneshot), the producing step is absent and the check is N/A — record
  execution evidence (command output, service-answers proof) against the
  issue body's acceptance criteria instead.

## Skipping policy

Never auto-skip; documenting deviations is the entire value of this
step.

## Source-repo stragglers

actualWork.md and wbs.md live in the devdoc, not the project source
repo — this step normally leaves the source tree untouched. If
writing the record surfaced a straggler in the source repo (a file
implement/quality commits missed), `git add` and `git commit -s` it
now. The commit step (12) comes next and verifies everything is
committed; analyze (13) then runs against the committed work.

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" document x
```

This step marks itself BY NAME, not by number — the row's number differs
between a pre-#558 checklist and a current one, and the name does not.
Use `-` instead of `x` if the step was skipped. Then run the Logging command above (if this
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
