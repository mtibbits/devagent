---
description: Surface latent bugs, side effects, ambiguities in the active issue's plan.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:improve

Step 5 of the 24-step devAgent workflow. The check runs in the
`devagent:plan-improver` agent, which cannot write files and carries the
checking procedure (three finding categories + the #286 pothole tripwire) as
its system prompt; it reads the plan cold and resolves the pothole register
itself (§12 registry: project paths → devdoc → plugin default). This command
resolves the tier, dispatches, writes the returned report to
`<issue-dir>/analysis/YYYY-MM-DD-improve.md`, triages the findings, and
appends the tagged `## Improvements` section to `imPlan.md`.

## Argument parsing

Per `commands/draft.md`. In short: optional `project`, optional issue
dir, remainder = `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists AND contains a `## Scope evaluation`
   section. If not, halt and tell the operator to run scope first.
3. **Dispatch** per the contract below. The checker authors the findings and
   returns them; it cannot write files.
4. **Write the returned body VERBATIM** to
   `<issue-dir>/analysis/YYYY-MM-DD-improve.md` (create `analysis/` if
   missing — pull scaffolds only the issue dir). Never rewrite the checker's
   findings in place — triage them, act on them, but leave the record as
   authored.
5. Validate the report (below), then **triage**: assign each finding
   `[merge]`, `[defer]`, or `[dismiss]` — tag assignment is the main
   session's judgment, not the checker's — and append the tagged
   `## Improvements` section to `imPlan.md` citing the artifact:

   ```markdown
   ## Improvements

   (triaged from analysis/2026-05-19-improve.md — context: subagent)

   ### Bugs
   - [merge] Task 2: strncpy with bound = strlen(src) is equivalent to
     strcpy; bound must be sizeof(dst) - 1 with explicit nul-term.

   ### Unintended side effects
   - [defer] foo.c is included by three other TUs; rebuild cost +12s.
     Document, do not change.

   ### Ambiguities
   - [merge] Task 1: which encoding does the source string use? If
     multi-byte, byte-truncation corrupts. Add encoding assertion.
   ```

6. Log the finding counts:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" improve \
     "Improvements appended; B bugs, S side-effects, A ambiguities; note: $NOTE"
   ```

## Dispatch contract

The shared checking-class dispatch procedure — tier resolution and the rc
exit-code table, the fresh-context path-packaging rule, the artifact-header
model enumeration, the degraded-harness fallback, and the dispatch-lint
retry-then-stuck protocol — is single-sourced in
`docs/checking-dispatch-contract.md` (#528). Read that file and follow it
verbatim, substituting this step's per-step deltas:

- **`<INTRO>`** — Fresh context is what makes the check real; the model override
  is conditional. The `core-improve` skill invoked below is a fork prompt bound
  to the agent — invoking it IS the fresh-context dispatch.
- **`<STEP>`** (canonical step number) — `5`; the main session resolves the
  tier per rung 1 with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 5`.
- **`<AGENT>`** (bound agent) — `plan-improver`: rc 0 dispatches the Agent tool
  with `subagent_type: devagent:plan-improver`; rc 3 dispatches the Agent tool
  with an explicit `model: opus` (the wrapper-carried step default) and stamps
  `agent-default (plan-improver)`.
- **`<SKILL>`** (rc-2 fork-prompt skill) — `core-improve`.
- **`<INPUTS>`** (rung-3 path packaging) — the absolute paths of `issue.md` and
  `imPlan.md` (including its `## Scope evaluation` AND its `## Load-bearing unknowns`
  section), `checklist.md` (the spike tripwire GATES on the spike row's glyph, so the checker
  must be able to read it — #536 redmr), plus `spike.md` when it exists (#536). The unknowns + spike verdicts are
  packaged EXPLICITLY because the step-5 checklist carries a tripwire over them, and a
  checklist item the checker never RECEIVES is a dead tripwire (#286).
- **`<TEMPLATE-RES>`** (rung-3 self-resolution) — the checker resolves the
  pothole register itself via `template.sh --project <project> show potholes`
  (#286: self-resolution is what makes the tripwire un-droppable).
- **`<CLASS>`** (rung-6 dispatch-lint class) — none; improve is not a verdict
  class, so run `dispatch-lint.sh <artifact> subagent` with no `--class`.
- **`<REJECT-SLUG>`** (rung-6 rejected-artifact slug) — `improve`.

## Halt and ask if

- Plan lacks `## Scope evaluation` (run scope first).
- Plan already has an `## Improvements` section (overwrite? append
  sub-section? abort?).
- More than 10 bugs surface — propose returning to the draft step rather
  than papering over a fundamentally broken plan.
- The checker reports a halt condition (unresolvable register, unlocatable
  source) — resolve it with the operator, then re-dispatch or run inline.

## Skipping policy

Never auto-skip. If the plan is trivially mechanical (e.g., a single typo
fix), surface the skip request rather than silently advancing:
"No improvements found; mark step `[-]` skipped?"

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" improve x
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
