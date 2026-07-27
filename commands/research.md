---
description: "Step 1: measure the world (read code/docs/upstream, run existing probes) before drafting; write cited findings + open unknowns."
allowed-tools: Read, Grep, Glob, WebFetch, Write, Edit, Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [Issue-N]"
---

# /devagent:research

Step 1 of the devAgent workflow — the OPTIONAL pre-draft research step (flow-order
between `0 pull` and `2 draft`). It runs only when the issue was flagged
`research: required` in its `## Workflow flags` block (pull.sh flips the `research`
row to `[ ]` at scaffold), or when the operator flips that row manually (the escape
hatch).

**Naming.** The research STEP (this command, driven by the `research: required` flag) is
distinct from the research checklist TEMPLATE (`checklist_template = research`, a
research-shaped issue type). This command is the step; it is unrelated to the template name.

## Discipline — read-only

Research MEASURES the world as it is and builds NOTHING: read code / docs / upstream
conventions, run EXISTING tools or probes, record what is learned versus assumed.
**`Write`/`Edit` are granted for exactly ONE purpose — authoring `<issue-dir>/research.md`.**
Do NOT write to the SOURCE tree, do not create or edit tests, do not prototype (that is the
spike step, #536). The only file this step may create or modify is `<issue-dir>/research.md`.

**This discipline is CONVENTIONAL, not enforced.** `Write`/`Edit` are granted unscoped, so
nothing mechanically stops a source-tree edit — the constraint is the contract above, and
review/redmr are the backstop. The stronger option (mirroring the #527/#529 checker agents:
dispatch to a Write-DENIED agent that returns `research.md` as text for the caller to write)
was considered and deferred — recorded here so the weaker choice is visible, not implied.

## Argument parsing

Per `commands/draft.md` (spec §6.1): optional `project`, optional `Issue[-Fork]-N`, rest
ignored. Defaults to the active project/issue.

## Precondition — the research row must be active

Read the `research` row's glyph (`checklist_step_state_by_name <checklist> research`).
Proceed only if it is `[ ]` (pending) or `[~]` (in-progress). If it is `[-]` (the
unflagged default), HALT and tell the operator: "research is not flagged for this
issue — flip the research row first (`/devagent:checklist-mark --by-name <issue-dir>
research ' '`, the escape hatch) or skip research." Do NOT
silently flip `[-]`→`[x]`.

## Workflow

1. Resolve `project`, `issue-dir`. Verify `issue.md` exists.
2. Read the issue. Identify the questions the issue's own text cannot answer — external API
   behavior, toolchain quirks, upstream conventions, unverified premises.
3. Investigate READ-ONLY: read source (cite `file:line`), read docs / upstream (cite URL),
   run existing probes or tools (cite the command + its output). Never assume; measure.
4. Write `<issue-dir>/research.md` with THREE required sections:

   ```markdown
   ## Questions
   - (what the issue can't answer from its own text)

   ## Findings
   - (each with a citation: file:line, URL, or command output)

   ## Open unknowns
   - (what research could NOT settle — candidate load-bearing unknowns for the #536 spike
     step's `## Load-bearing unknowns` plan section; cross-ref)
   ```

   Every `## Findings` entry MUST carry a citation. `## Open unknowns` is the honest record of
   what remains unverified; the draft step disposes of each (design around or carry forward).

## Logging

After completion:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" research \
  "research.md written (Q questions, F findings, U open unknowns)"
```

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" research x
```

This step marks itself BY NAME, not by number — the row's number differs between
a pre-#558 checklist and a current one, and the name does not. Use `-` instead of
`x` if the step was skipped. Then run the Logging command above.

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first step in the issue's checklist.md not
marked `[x]` or `[-]` -- read that line, take the verb after the
step number, and substitute it into the question. (For a flagged issue
this is normally `draft`, which consumes `research.md` via its
`## Pre-plan inputs` block.)

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
