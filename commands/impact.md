---
description: Measure and record the real-world impact of a merged change. Invokes core-impact skill.
allowed-tools: Bash, Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note: paths to evidence files]"
---

# /devagent:impact

Step 18 of the 22-step devAgent workflow. Invokes the `core-impact`
skill to write `<issue-dir>/impact.md`.

## Argument parsing

Per `commands/draft.md`. `$NOTE` is the conventional channel for
operator-supplied evidence paths (e.g.,
"benchmark plot at /abs/path/to/plot.png; baseline csv at /abs/path/baseline.csv").

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file shows the issue is merged (mr_url present and
   mr-state is `merged`). If not, halt — measuring impact on
   un-merged code is meaningless.
3. Invoke `core-impact` with `$ISSUE_DIR` and `$NOTE`.
4. Skill writes impact.md and calls `scripts/checklist-log.sh`.

## Halt and ask if

- Issue is not merged.
- Performance label present but no evidence path in `$NOTE`.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.

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
