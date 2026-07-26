---
description: Alias for `/devagent:wbs update` (workflow step 20)
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [args]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wbs.sh" update $ARGUMENTS` with the user's arguments.

This is the workflow step-20 entrypoint. Identical behavior to
`/devagent:wbs update`; exists as a separate command so the 24-step
workflow chaining (`--auto`, `--through`) and skill mapping can
reference a single verb.

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" <N> x
```

`<N>` is this step's number on the issue's checklist (17 for `updatewbs`);
`$ISSUE_DIR` is the active issue's directory (resolve it from project
state if not already bound). Use `-` instead of `x` if the step was
skipped. This step is backed by `wbs.sh`, which does NOT self-mark, so the
mark above is the only thing advancing step 20.

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
