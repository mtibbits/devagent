---
description: Run red-team adversarial review of the MR before shipping. Invokes core-redmr skill.
allowed-tools: Bash, Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:redmr

Step 14 of the 21-step devAgent workflow. Invokes the `core-redmr`
skill to run `${CLAUDE_PLUGIN_ROOT}/templates/redteam_mr.md` against the MR body and diff,
classify findings by severity, and write the report to
`<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists.
3. Invoke `core-redmr`.
4. Skill writes the report and logs the finding counts in the
   parser-compatible format from spec §14.4. The skill itself calls
   `scripts/checklist-log.sh`.
5. **Commit applied fixes (#148).** If addressing findings modified
   (or added) any tracked file in the project source repo, `git add` +
   `git commit -s` (new commit, not amend) before marking the step —
   ship.sh (15) refuses to push when tracked files are modified.
   Devdoc artifacts (analysis/, mr.md) stay under `commit_devdoc`.

## Halt and ask if

- mr.md missing.
- Skill reports BLOCKING findings — do NOT advance to ship.

## Skipping policy

Never auto-skip; red-team is an unconditional gate per spec §6.3
principle and the operator's principal value prop.

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
