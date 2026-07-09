---
name: core-preship
description: Use when running step 21 of the devAgent workflow to verify, in fresh context, that the committed branch satisfies the issue's acceptance criteria and contains every blocking finding before ship
when-to-use: After /devagent:redmr and before /devagent:ship. Run as part of /devagent:preship.
---

# devagent-preship

Step 21 of the devAgent 22-step workflow (file-ordered between redmr and
ship; the number is unique, not sequential — file order is execution
authority). Verifies the branch as-committed and writes
`<issue-dir>/preship.md` with evidence.

## Overview

The #101/#102 incident: review found fixes, redmr recorded "0 blocking", and
the pushed branch still lacked the fixes — the checks had evaluated the
working tree while ship pushed the commits. #148 closed the mechanical half
(ship refuses a dirty tree). This step is the semantic half: three
verifications against the branch as-committed, each with evidence, so a
maintainer (or the operator weeks later) has an artifact proving the branch
was checked before push. The 2026-07 sprint hit the same class three more
times as MR-record staleness (Issues 116/151/242) — caught each time by a
red team; this step mechanizes the catch.

## Inputs

- `$ISSUE_DIR`, `$NOTE`, and the active PROJECT name — resolved by the
  command wrapper per spec §6.1; when the skill is invoked directly,
  default to state's `active_project`. If no project resolves, treat the
  tier as unconfigured (dispatch with no override).
- Reads:
  - `<issue-dir>/issue.md` (the acceptance criteria under verification).
  - `<issue-dir>/mr.md` (claims the artifact cross-checks).
  - Latest-dated `<issue-dir>/analysis/*-review.md` and `*-redmr.md`
    (findings input; revision-block scoping arrives with #76).
  - `git log/diff <baseline_sha>..HEAD` — the literal push content.
- Writes: `<issue-dir>/preship.md`.

## Dispatch contract (#151)

Run this verification in FRESH CONTEXT whenever the harness provides a
subagent mechanism (Claude Code's Agent/Task tool does). Fresh context is
the point: the implementing session reviews what it remembers intending;
preship reviews what is on disk. The model override is conditional; fresh
context is not.

1. **Resolve the model tier** (optional):
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 21 || true)"`.
   Pass the CANONICAL step number (21) even on a renumbered checklist —
   the class map is keyed to canonical numbers (config.sh). Empty ⇒
   dispatch with NO model override (inherit the session model). A
   per-issue `.devagent-step-models` marker (#291) may supply the tier —
   a stderr `per-issue` provenance line means record
   `model: <tier> (per-issue)` (or `inherit (per-issue)`) in the
   artifact header. A nonzero exit WITH an error on stderr (stderr
   WITHOUT a `per-issue` provenance line) is a bad marker: STOP and fix
   or remove it — do NOT dispatch on inherit.
2. **Package inputs as paths, not conversation.** The dispatch prompt
   contains only: the absolute paths of `issue.md`, `mr.md`, the
   latest-dated review/redmr artifacts, the repo directory plus the
   literal diff spec `<baseline_sha>..HEAD`, and the output artifact path
   `<issue-dir>/preship.md`. Do NOT paste your recollection of the change
   or prior findings into the prompt — deriving everything from disk is
   exactly how a stranded fix gets caught.
3. **Dispatch** one subagent with the resolved override (per step 1). If
   dispatch fails because the tier is unavailable, retry once with NO
   override and record the degradation in the artifact header.
4. **The subagent authors the artifact** (three verifications below, each
   PASS/FAIL with evidence) and returns only per-verification results.
   The MAIN session enforces the failure protocol on the returned
   results; a dispatched checker that cannot complete a verification
   records it as FAIL with the reason instead of asking.
5. **Mandatory artifact header.** First lines of the artifact:
   `context: subagent` (or `context: inline`), and `model: <tier>` (or
   `model: inherit`, or `model: inherit (fallback from <tier>)`, or the
   per-issue forms `model: <tier> (per-issue)` /
   `model: inherit (per-issue)`).
6. **Inline fallback.** When no subagent mechanism exists, run inline as
   before; the artifact MUST record `context: inline`.
7. **Report validation — retry-then-stuck (#360).** When this ran DISPATCHED,
   validate the returned artifact before adopting it:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<preship.md>" subagent
   --class preship`. On FAIL (a garbled / no-tool-use report — the
   #117/#122/#76/#315 misfire class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-preship-attempt<N>.md`, re-dispatch ONCE
   with an explicit "your previous response did no work — actually do the work with
   tools" nudge, and if it FAILs again mark the step `[!]` with the lint reason.
   Never adopt a garbled report as a verdict (the #315 lesson). Inline runs skip
   the lint (the operator sees the artifact directly).

## Checklist

The verifications — each recorded in `preship.md` as PASS or FAIL
with evidence, never "looks done":

1. **Acceptance criteria executed.** Each criterion from issue.md is RUN
   against the branch (command + output per criterion, pass/fail). A
   criterion that cannot be executed (e.g. requires merge) is recorded
   as N/A with the reason, not PASS.
2. **Findings applied and committed.** Every BLOCKING/MAJOR (or
   request-changes-class) finding from the latest-dated review and redmr
   artifacts is located in the COMMITTED diff (`git diff
   baseline..HEAD`), cited by file/hunk. A finding whose fix exists only
   in the working tree is a FAIL — that is the #101/#102 stranded-fix
   class this step exists to catch.
3. **Push preview.** `git log/diff baseline..HEAD` is inspected as the
   literal content ship will push; any mismatch with the working tree
   (uncommitted tracked changes) is reported. mr.md's claims (commit
   count, test counts) are cross-checked against the preview.
4. **Evidence cross-check (#359).** Run the mechanized checker; a nonzero
   exit is a FAIL recorded in preship.md (with its stderr):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-evidence.sh"
   ```

   It verifies mr.md's `## Evidence` block against the newest
   `analysis/<date>-suite-count.txt` + git (artifact head == HEAD, tree
   clean, suite green, the `suite:` line exact, `files:` == the
   baseline..HEAD diff count). An mr.md with NO Evidence block warns and
   passes (back-compat). This mechanizes the hand cross-check verification 3
   was doing for suite/file numbers.

## Failure protocol

- ANY FAIL ⇒ the MAIN session runs
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" "$ISSUE_DIR" "preship: <one-line failure list>"`
  and STOPS. NB: checklist-stuck.sh takes NO step-number argument — it
  marks the CURRENT step, which is preship when steps 0-14 are terminal
  (guaranteed under next.sh dispatch; on manual out-of-order invocation,
  verify the checklist's current step is 21 first). The `[!]` plus STUCK
  file is the halt next.sh honors (exit 1 + STUCK display); recovery is
  `/devagent:unstuck` after addressing the failures, then re-run preship.
- All PASS ⇒ mark step 21 `[x]` per the Completion handoff.

## Zero-diff (artifact-only) issues

Detected via `zero_diff_classify` (lib/zerodiff.sh) on `baseline..HEAD`:
`empty` means nothing ships (see Skipping policy); `indeterminate`
(missing/stale baseline) NEVER auto-skips — fail loud and let the
operator fix the state (the #116/#242 discipline).

## Halt and ask if

- `mr.md` does not exist (draftmr step skipped).
- The checklist contains step 14 (redmr) but no `analysis/*-redmr.md`
  exists — the producing step ran or should have; do not silently verify
  against nothing. (docs-only checklists lack step 14: the review report
  alone is the findings input. A docs-only issue whose step 13 is present
  but produced no `analysis/*-review.md` is the same halt, inverse #133.)
- `baseline_sha` or `branch` is missing from state — preship cannot
  identify the push content; fix state, do not guess.

## Skipping policy

Auto-skip ONLY on the zero-diff `empty` verdict above (mark `[-]`, log,
advance). Never otherwise — this step is the last gate before content
leaves the machine.

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" preship \
  "Preship: A/B ACs pass, F findings located, push-preview MATCH|MISMATCH; note: $NOTE"
```

## Templates referenced

- None directly (the artifact is free-form with the mandatory header;
  review/redmr artifacts are inputs, not templates).

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
