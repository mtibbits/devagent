---
description: "Step 17: fresh-context verification that the committed branch satisfies the ACs and contains all findings, before ship."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:preship

Step 17 of the devAgent 25-step workflow (between redmr (16) and ship (18);
since #558 the numbers agree with file order by construction).
The verification runs in the `devagent:preship-verifier` agent, which cannot
write files and carries the five verifications as its system prompt; this
command resolves the tier, dispatches, writes the returned artifact to
`<issue-dir>/preship.md`, and enforces the failure protocol.

## Argument parsing

Per `commands/draft.md`.

## Workflow

First, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/quarantine-check.sh" $ARGUMENTS`. On any non-zero exit, print its stderr verbatim and STOP: no further step, no checklist write, no log line, no completion handoff. Exit 11 is a quarantine (wait for the operator); 9 and 10 are trust refusals.

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `mr.md` exists (draftmr ran) and the redmr artifact exists —
   UNLESS the issue's checklist does not contain step 16 (docs-only): a
   prerequisite whose producing step is absent is **N/A**, and the review
   report alone is the findings input. Do not halt on the absent step;
   DO halt when the step is present but its artifact is missing.

**Preflight (between 2 and 2a) (#1122).** The Zero-diff section below is applied
first; an empty diff never reaches this preflight. In order, each its own Bash call
with `<project> <Issue-N>`: **evidence check, claims check, head pin, dispatch**.
Nothing from the preflight enters the dispatch prompt, and
**neither `run-suite.sh` nor `evidence-stamp.sh`** runs here. It also runs on a
re-run after ship, where a correction changes `mr.md` only.

- **Evidence check**, by recipe `stop` below:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-evidence.sh" <project> <Issue-N> --attestable-exit`.
  Exit 0 or 4: continue (on 4 only attestations are absent, and the verifier
  attests). Exit 9, 10 or 11: the quarantine rule above. Anything else:
  **STOP before any dispatch**. The step is marked `[!]` with `preship: evidence preflight: <first
  failure line>`, **no preship.md** is written, and an existing one is first moved to
  `analysis/<date>-<HHMMSS>-preship-superseded.md` and logged, so no older verdict sits
  beside the `[!]`. The first failure line is stderr's first `  - ` entry (plus
  `(+N more)`), else its first non-empty line, else `(no stderr)`.
- **Claims check**, by recipe `claims` below; it reads and reports, never writes.
  Exit 0: continue. Exit 9, 10 or 11: the quarantine rule. Any other exit but 3:
  the check **could not run**; log it, then dispatch anyway.
- Exit 3: each report is **a prompt to look, not an instruction**.
  Before acting on a report, grep the checklist log for `claims: mr.md:<L> left as written`;
  if the logged text equals the current line (truncated as logged), keep that
  decision and log nothing new. Do not revisit a line left as written. Otherwise: (a) the claim
  is about the branch now and the found value is right: **correct the line**;
  (b) it is right for an earlier or partial run: **keep the value**, and
  **name the commit** if the log or git establishes it; (c) otherwise wrong:
  **leave the line as written**. **Never edit the `## Evidence` block.** Log each
  decision by recipe `log`.
- Re-run the check only after a run that edited `mr.md`, **at most three runs**. A
  line still reported on the last run, and not left as written, is logged
  **unresolved**, and **the verifier is still dispatched**. Last, log the
  `preflight:` line (recipe `log`, K=preflight).
- **Shell safety.** Script stderr and `mr.md` text hold backticks, `$` and quotes, and
  a double-quoted argument runs them as command substitution (the stamper's remedy
  text is written ``with `bash "$CLAUDE_PLUGIN_ROOT/scripts/evidence-stamp.sh" …` ``).
  Never interpolate such text into a command line: capture stderr to a file, read
  `mr.md` lines with `sed` inside the command, take model-authored text through a
  quoted heredoc, build each message with `printf -v msg`, and pass `"$msg"`. Run each
  recipe as written: set `ISSUE_DIR` and the inputs its comment names at the top of
  the same Bash call, and substitute only `<project>` and `<Issue-N>`.

```bash
# recipe: stop     (evidence check, stop case; <project> <Issue-N> are substituted)
err="$(mktemp)"; rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-evidence.sh" <project> <Issue-N> --attestable-exit 2>"$err" || rc=$?
cat "$err" >&2
case "$rc" in 0|4|9|10|11) ;; *)
  first="$(grep -m1 '^  - ' "$err")"; first="${first#  - }"
  [ -n "$first" ] || first="$(grep -m1 . "$err")"; [ -n "$first" ] || first='(no stderr)'
  more=$(( $(grep -c '^  - ' "$err") - 1 )); [ "$more" -gt 0 ] && first="$first (+$more more)"
  if [ -f "$ISSUE_DIR/preship.md" ]; then
    sup="analysis/$(date +%F-%H%M%S)-preship-superseded.md"; mkdir -p "$ISSUE_DIR/analysis"
    mv "$ISSUE_DIR/preship.md" "$ISSUE_DIR/$sup"
    printf -v msg 'preflight: moved preship.md to %s' "$sup"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" preship "$msg"
  fi
  printf -v msg 'preship: evidence preflight: %s' "$first"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" "$ISSUE_DIR" "$msg" ;;
esac
rm -f "$err"; echo "evidence rc=$rc"
```
```bash
# recipe: claims   (one run, of at most three; <project> <Issue-N> are substituted)
d="${TMPDIR:-/tmp}/devagent-claims-<Issue-N>"; rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/claims-check.sh" <project> <Issue-N> >"$d.out" 2>"$d.err" || rc=$?
cat "$d.out"; cat "$d.err" >&2; echo "claims rc=$rc"
```
```bash
# recipe: log      (K = corrected | 'named commit' | 'left as written' | unresolved | 'could not run' |
#                   preflight; L = the mr.md line ('' for the last two); OLDF = line L saved before the
#                   edit by: sed -n "${L}p" "$ISSUE_DIR/mr.md" > "$OLDF"; n = the claims run number;
#                   RC = the last claims exit; EVRC = the evidence exit)
d="${TMPDIR:-/tmp}/devagent-claims-<Issue-N>"
_t() { if [ "${#1}" -gt 200 ]; then printf '%s…' "${1:0:200}"; else printf '%s' "$1"; fi; }
cur=""; [ -z "$L" ] || IFS= read -r cur < <(sed -n "${L}p" "$ISSUE_DIR/mr.md"); cur="${cur%$'\r'}"
case "$K" in
  corrected|'named commit') IFS= read -r old < "$OLDF"; old="${old%$'\r'}"
    printf -v msg "claims: mr.md:%s %s: '%s' -> '%s'" "$L" "$K" "$(_t "$old")" "$(_t "$cur")" ;;
  'left as written') IFS= read -r why <<'EOF'
<the reason, verbatim>
EOF
    printf -v msg "claims: mr.md:%s left as written: '%s' — %s" "$L" "$(_t "$cur")" "$why" ;;
  unresolved) printf -v msg "claims: mr.md:%s unresolved after run %s: '%s'" "$L" "$n" "$(_t "$cur")" ;;
  'could not run') first="$(grep -m1 . "$d.err" 2>/dev/null)"; [ -n "$first" ] || first='(no stderr)'
    printf -v msg 'claims: could not run (exit %s): %s; verifier dispatched' "$RC" "$first" ;;
  preflight) sum="$(grep -m1 '^claims-check: checked ' "$d.out" 2>/dev/null)"; [ -n "$sum" ] || sum='(none)'
    printf -v msg 'preflight: evidence exit %s; claims runs %s, last exit %s; %s' "$EVRC" "$n" "$RC" "$sum" ;;
esac
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" preship "$msg"
```

2a. **Pin the head (#885)**, as its own Bash call; halt on non-zero:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-verified-head.sh" pin <project>`.
   It persists HEAD as `preship_pin_head` and prints its SHA; paste that SHA
   into the `<INPUTS>` diff spec as text (no shell variable survives the
   verifier's turn, Issue-578).
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
  `<baseline_sha>..<SHA>`, `<SHA>` being step 2a's printed SHA, literally.
- **`<TEMPLATE-RES>`** (rung-3 self-resolution) — This step resolves no template.
- **`<CLASS>`** (rung-6 dispatch-lint class) — `--class preship`.
- **`<REJECT-SLUG>`** (rung-6 rejected-artifact slug) — `preship`.

## Failure protocol

- ANY FAIL ⇒ run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" "$ISSUE_DIR" "preship: <one-line failure list>"`
  and STOP. NB: without `--step`, checklist-stuck.sh marks the
  CURRENT step, which is preship when steps 0-16 are terminal (guaranteed under
  next.sh dispatch; on manual out-of-order invocation, verify the checklist's
  current step is 17 first; a post-ship re-run is the exception, see
  "Re-verifying after ship"). The `[!]` plus STUCK file is the halt next.sh
  honors (exit 1 + STUCK display); recovery is `/devagent:unstuck` after
  addressing the failures, then re-run preship.
- All PASS ⇒ run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-verified-head.sh" record <project>`
  as its own Bash call, no SHA argument (it reads the pin back): it writes
  `verified_head`, the head mergemr may merge at. Non-zero is a FAIL whose
  stderr line is the `preship: …` reason above. Exit 0 ⇒ mark step 17 `[x]`
  per the Completion handoff below.

## Re-verifying after ship

mergemr (step 20) merges only at `verified_head`; a head that moved after ship
stops it `[!]` until a fresh preship passes. After a **fix push** (rule 15):
re-run `scripts/run-suite.sh` and `scripts/evidence-stamp.sh` (`commands/review.md`
6a), push, then preship. After a **merge-forward** (rule 14): run
`scripts/rebaseline.sh` first, then the same pair, push, then preship. The
preflight runs on this re-run too; its evidence stop is a failed post-ship preship,
and a claims correction changes `mr.md` only, never the posted MR body.

A passing `record` clears a mergemr stop of rule 10, 11, 14 or 15, or a
`preship: …` stop on the mergemr row (row back to `[ ]`, STUCK removed, logged
`preship: cleared mergemr stop (…)`). Nothing else: rule 9 and every other
stop, and a failed post-ship preship that marked mergetoall `[!]`, need
`/devagent:unstuck`.

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

The preflight logs each outcome in exactly one spelling (Issue-586), through recipes
`stop` and `log`; `<old>`, `<new>` and `<text>` are the whole `mr.md` line, truncated
to 200 characters plus `…`. An evidence stop's reason is its STUCK line,
`preship: evidence preflight: <first failure line>`.

```
claims: mr.md:<L> corrected: '<old>' -> '<new>'
claims: mr.md:<L> named commit: '<old>' -> '<new>'
claims: mr.md:<L> left as written: '<text>' — <reason>
claims: mr.md:<L> unresolved after run <n>: '<text>'
claims: could not run (exit <rc>): <first stderr line>; verifier dispatched
preflight: moved preship.md to analysis/<date>-<HHMMSS>-preship-superseded.md
preflight: evidence exit <rc>; claims runs <n>, last exit <rc>; <the last claims summary line, or (none)>
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
