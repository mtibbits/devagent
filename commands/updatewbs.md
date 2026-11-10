---
description: Alias for `/devagent:wbs update` (workflow step 21)
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [args]"
---

## Workflow

First, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/quarantine-check.sh" $ARGUMENTS`. On any non-zero exit, print its stderr verbatim and STOP: no further step, no checklist write, no log line, no completion handoff. Exit 11 is a quarantine (wait for the operator); 9 and 10 are trust refusals.

Then run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wbs.sh" update $ARGUMENTS` with the user's arguments.

This is the workflow step-21 entrypoint. Identical behavior to
`/devagent:wbs update`; exists as a separate command so the 25-step
workflow chaining (`--auto`, `--through`) and skill mapping can
reference a single verb. Like `/devagent:wbs update`, this step also sorts
each parent's children by dependency, then priority (#803).

**A non-zero exit is not done (#749).** `wbs.sh update` exits 1 when it could
not write `WBS.md` — for example the devDoc repository lock was held past
its bound (spec §3.3). Then print its stderr verbatim and STOP: do not mark
the step `x` and do not run the completion handoff. Mark it stuck instead,
which ends an `--auto` chain:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" --name updatewbs "$ISSUE_DIR" "<first stderr line>"
```

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" updatewbs x
```

This step marks itself BY NAME, not by number — the row's number differs
between a pre-#558 checklist and a current one, and the name does not.
`$ISSUE_DIR` is the active issue's directory (resolve it from project
state if not already bound). Use `-` instead of `x` if the step was
skipped. This step is backed by `wbs.sh`, which does NOT self-mark, so the
mark above is the only thing advancing this step.

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
