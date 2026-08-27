---
description: "Step 17: fresh-context verification that the committed branch satisfies the ACs and contains all findings, before ship."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:preship

Step 17 of the devAgent 24-step workflow (between redmr (16) and ship (18);
since #558 the numbers agree with file order by construction).
The verification runs in the `devagent:preship-verifier` agent, which cannot
write files and carries the five verifications as its system prompt; this
command resolves the tier, dispatches, writes the returned artifact to
`<issue-dir>/preship.md`, and enforces the failure protocol.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `mr.md` exists (draftmr ran) and the redmr artifact exists —
   UNLESS the issue's checklist does not contain step 16 (docs-only): a
   prerequisite whose producing step is absent is **N/A**, and the review
   report alone is the findings input. Do not halt on the absent step;
   DO halt when the step is present but its artifact is missing.
3. **Dispatch** per the contract below. The checker authors the artifact and
   returns it; it cannot write files.
4. **Write the returned body to `<issue-dir>/preship.md` VERBATIM.** Do not
   edit, summarize, or "fix" it — authorship stays with the checker, and a
   main session that rewrites a verdict it dislikes is the failure this step
   exists to prevent.
5. Validate, then enforce the failure protocol (both below).

## Dispatch contract

The shared checking-class dispatch procedure — tier resolution and the rc
exit-code table, the fresh-context path-packaging rule, the artifact-header
model enumeration, the degraded-harness fallback, and the dispatch-lint
retry-then-stuck protocol — is single-sourced in
`docs/checking-dispatch-contract.md` (#528). Read that file and follow it
verbatim, substituting this step's per-step deltas:

- **`<INTRO>`** — Fresh context is not conditional; the model override is. The
  implementing session reviews what it remembers intending; preship reviews what
  is on disk.
- **`<STEP>`** (canonical step number) — `17`; the main session resolves the
  tier per rung 1 with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 17`.
- **`<AGENT>`** (bound agent) — `preship-verifier`: rc 0 dispatches the Agent
  tool with `subagent_type: devagent:preship-verifier`; rc 3 dispatches the
  Agent tool with an explicit `model: opus` (the wrapper-carried step default)
  and stamps `agent-default (preship-verifier)`.
- **`<SKILL>`** (rc-2 fork-prompt skill) — `core-preship`.
- **`<INPUTS>`** (rung-3 path packaging) — the absolute paths of `issue.md`,
  `mr.md`, and the latest-dated review/redmr artifacts, plus the diff spec
  `<baseline_sha>..HEAD`.
- **`<TEMPLATE-RES>`** (rung-3 self-resolution) — This step resolves no template.
- **`<CLASS>`** (rung-6 dispatch-lint class) — `--class preship`.
- **`<REJECT-SLUG>`** (rung-6 rejected-artifact slug) — `preship`.

## Failure protocol

- ANY FAIL ⇒ run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" "$ISSUE_DIR" "preship: <one-line failure list>"`
  and STOP. NB: checklist-stuck.sh takes NO step-number argument — it marks the
  CURRENT step, which is preship when steps 0-16 are terminal (guaranteed under
  next.sh dispatch; on manual out-of-order invocation, verify the checklist's
  current step is 21 first). The `[!]` plus STUCK file is the halt next.sh
  honors (exit 1 + STUCK display); recovery is `/devagent:unstuck` after
  addressing the failures, then re-run preship.
- All PASS ⇒ mark step 17 `[x]` per the Completion handoff below.

## Zero-diff (artifact-only) issues

Detected via `zero_diff_classify` (lib/zerodiff.sh) on `baseline..HEAD`:
`empty` means nothing ships (mark `[-]`, log, advance); `indeterminate`
(missing/stale baseline) NEVER auto-skips — fail loud and let the operator fix
the state (the #116/#242 discipline).

## Halt and ask if

- `mr.md` missing (run draftmr first).
- Step 16 present in the checklist but no `analysis/*-redmr.md` (and the
  docs-only inverse: step 15 present but no review artifact).
- State lacks `baseline_sha`/`branch` (preship cannot identify the push
  content) — fix state, do not guess.

## Skipping policy

Zero-diff auto-skip only (`empty` ⇒ `[-]`; `indeterminate` never auto-skips).
Never skip otherwise — this step is the last gate before content leaves the
machine.

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" preship "Preship: A/B ACs pass, F findings located, push-preview MATCH|MISMATCH; note: $NOTE"
```

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" preship x
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
