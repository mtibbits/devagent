---
name: core-redmr
description: Use when running step 14 of the devAgent workflow to run a red-team adversarial review of the MR body and diff before shipping upstream
when-to-use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
---

# devagent-redmr

Step 14 of the devAgent 21-step workflow. Runs the project's MR
red-team prompt (`${CLAUDE_PLUGIN_ROOT}/templates/redteam_mr.md`, resolved per §12 registry)
against `<issue-dir>/mr.md` plus the branch diff. Produces a severity-
classified findings report and refuses to silently advance past
blocking findings.

## Overview

Red-team is adversarial: assume the reviewer is hostile and looking
for any reason to reject. The output is a list of findings classified
by severity. The operator must address every BLOCKING finding before
the ship step will fire.

## Inputs

- `$ISSUE_DIR`, `$NOTE`, and the active PROJECT name — resolved by the
  command wrapper per spec §6.1; when the skill is invoked directly,
  default to state's `active_project`. If no project resolves, treat the
  tier as unconfigured (dispatch with no override).
- Reads:
  - `<issue-dir>/mr.md` (the MR body under attack).
  - `<issue-dir>/imPlan.md`, `actualWork.md` (for context).
  - `git diff <baseline_sha>..HEAD` (the actual code change).
  - Resolved `${CLAUDE_PLUGIN_ROOT}/templates/redteam_mr.md` (per spec §12 registry).
- Writes: `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Dispatch contract (#151)

Run this red-team in FRESH CONTEXT whenever the harness provides a
subagent mechanism (Claude Code's Agent/Task tool does). Fresh context is
what makes the attack real: the #101/#102 incident — redmr evaluated the
working tree it had itself just edited and recorded "0 blocking" against
a branch that lacked the fixes — is the failure class this prevents. The
model override is conditional; fresh context is not.

1. **Resolve the model tier** (optional):
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 14 || true)"`.
   Pass the CANONICAL step number (14) even on a renumbered checklist —
   the class map is keyed to canonical numbers (config.sh). Empty ⇒
   dispatch with NO model override (inherit the session model).
2. **Package inputs as paths, not conversation.** The dispatch prompt
   contains only: the absolute paths of `mr.md`, `imPlan.md`,
   `actualWork.md`, the RESOLVED red-team template
   (`redteam_mr.md` per the §12 registry walk), the repo directory plus
   the literal diff spec `<baseline_sha>..HEAD`, and the output artifact
   path `<issue-dir>/analysis/YYYY-MM-DD-redmr.md` (create `analysis/`
   if missing). Do NOT paste the MR summary, your recollection of the
   change, or prior findings into the prompt — the checker must derive
   everything from disk, which is exactly how it catches a report/branch
   divergence.
3. **Dispatch** one subagent with the resolved override (per step 1).
   If dispatch fails because the tier is unavailable, retry once with NO
   override and record the degradation in the artifact header.
4. **The subagent authors the artifact** (severity-classified findings
   per the Checklist below) and returns only counts + verdict. The main
   session triages, applies fixes, and commits them per #148 — it never
   rewrites the subagent's findings in place. Checklist item 6's B>0
   gate and the Halt-and-ask rules bind the MAIN session (enforced on the
   returned counts); a dispatched checker that cannot classify a finding
   records it un-tagged in the artifact instead of asking.
5. **Mandatory artifact header.** First lines of the artifact:
   `context: subagent` (or `context: inline`), and `model: <tier>` (or
   `model: inherit`, or `model: inherit (fallback from <tier>)`).
6. **Inline fallback.** When no subagent mechanism exists, run inline as
   before; the artifact MUST record `context: inline`.

## Checklist

1. **Resolve template.** Walk §12 registry to locate `redteam_mr.md`.
   Halt if unresolvable.
2. **Load the prompt.** Read the resolved redteam_mr.md verbatim;
   it is the contract for what to attack and how.
3. **Apply prompt to mr.md + diff.** Run every adversarial check the
   template specifies. Produce one finding per identified concern.
4. **Classify every finding** with one of these severity tags:
   - `[BLOCKING]` — reviewer will reject the MR until fixed.
   - `[MAJOR]` — reviewer will request changes; merge stalls.
   - `[MINOR]` — reviewer will nit but merge if rest is clean.
   - `[INFO]` — informational; no action required.
5. **Write findings to** `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`
   in this format:

   ```markdown
   # Red-team review — <date>

   ## Summary
   B blocking, M major, m minor, I info

   ## Findings
   ### [BLOCKING] <one-line title>
   <evidence: file:line, quote, why this blocks>
   <suggested remediation>
   ```
6. **Refuse silent advance.** If B > 0, the MAIN session refuses to
   advance: report the failure and tell the operator to address findings
   before re-running, or mark `[!]` stuck via `/devagent:stuck`. (Under
   dispatch the subagent only returns counts — this gate is the main
   session's to enforce.)
7. **Commit applied fixes (#148).** If addressing findings modified
   (or added) any tracked file in the project source repo — the issue
   branch — `git add` + `git commit -s` them before marking step 14.
   A new signed-off commit, not an amend (the fix delta stays
   auditable; amending after a prior ship would force-push). ship.sh
   (15) refuses to push when tracked files are modified. Committing
   here also re-anchors this report to `baseline..HEAD`, so the report
   and the pushed branch cannot diverge (the #101/#102 failure).
   Devdoc artifacts (analysis/, mr.md) are NOT committed here; they
   are governed by `commit_devdoc` at cleanup.

## Halt and ask if

- `mr.md` does not exist (draftmr step skipped).
- `redteam_mr.md` cannot be resolved.
- Findings include items the skill cannot classify confidently —
  surface them un-tagged and ask the operator to triage rather than
  inventing a severity.

## Skipping policy

Never auto-skip. Red-team is an unconditional gate on shipping
upstream per operator's principal value prop. If the operator insists
on skipping (private fork-only experimentation, etc.), surface
"this means shipping un-red-teamed; confirm?" and require
acknowledgement.

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" redmr \
  "Red-team: B blocking, M major, m minor, I info (template: $TEMPLATE_PATH); note: $NOTE"
```

The format above is contract: `statusreport.sh` parses for the word
`blocking` and an integer to surface failed red-teams in status
reports per spec §14.4.

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/redteam_mr.md` (the adversarial prompt itself).

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
