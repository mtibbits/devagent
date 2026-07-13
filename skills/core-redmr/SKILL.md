---
name: core-redmr
description: Use when running step 14 of the devAgent workflow to run a red-team adversarial review of the MR body and diff before shipping upstream
when_to_use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
user-invocable: false
---

# devagent-redmr

Step 14 of the devAgent 22-step workflow. Runs the project's MR
red-team prompt (the resolved `redteam_mr.md`, per the §12 registry)
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
  - Resolved `redteam_mr.md` (per spec §12 registry: project paths → devdoc → plugin default).
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
   dispatch with NO model override (inherit the session model). A
   per-issue `.devagent-step-models` marker (#291) may supply the tier —
   a stderr `per-issue` provenance line means record
   `model: <tier> (per-issue)` (or `inherit (per-issue)`) in the
   artifact header. A nonzero exit WITH an error on stderr (stderr
   WITHOUT a `per-issue` provenance line) is a bad marker: STOP and fix
   or remove it — do NOT dispatch on inherit.
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
   `model: inherit`, or `model: inherit (fallback from <tier>)`, or the
   per-issue forms `model: <tier> (per-issue)` /
   `model: inherit (per-issue)`).
6. **Inline fallback.** When no subagent mechanism exists, run inline as
   before; the artifact MUST record `context: inline`.

## Report validation — retry-then-stuck (#360)

When this red-team ran DISPATCHED, validate the returned artifact before adopting it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<artifact>" subagent --class redmr
```

On FAIL (a garbled / no-tool-use report — the #117/#122/#76/#315 misfire class):
archive the reject to `<issue-dir>/analysis/rejected/<date>-redmr-attempt<N>.md`,
re-dispatch ONCE with an explicit "your previous response did no work — actually do
the work with tools" nudge, and if it FAILs again mark the step `[!]` with the lint
reason. Never adopt a garbled report as a verdict (the #315 lesson). Inline runs
skip the lint (the operator sees the artifact directly).

## Checklist

1. **Resolve template.** Walk §12 registry to locate `redteam_mr.md`.
   Halt if unresolvable.
2. **Load the prompt.** Read the resolved redteam_mr.md verbatim;
   it is the contract for WHAT to attack. Format precedence (#134): the
   template defines the checks; THIS skill defines the output — severity
   taxonomy, summary counts, verdict vocabulary, and the checklist log
   line, nothing else. If a resolved template (including a project
   override) specifies a different output format, this skill's output contract wins.
3. **Apply prompt to mr.md + diff.** Run every adversarial check the
   template specifies. Produce one finding per identified concern.
   **Spec-touch question (#435; always run, independent of the template):**
   does this diff ADD, RENAME, or REMOVE a config key, a command, a hook, or a
   top-level directory that the spec must name — and does it carry no
   corresponding spec change? Renames and removals lag the spec identically to
   adds, so the question covers all three. If the answer is yes (a spec-relevant
   surface changed with no matching spec edit), raise it as a `[MAJOR]` finding
   ("spec lag: <surface> changed without a spec update"). A diff that touches no
   config key / command / hook / top-level directory answers the question
   trivially and proceeds unchanged.
4. **Classify every finding** with one of these severity tags:
   - `[BLOCKING]` — reviewer will reject the MR until fixed.
   - `[MAJOR]` — reviewer will request changes; merge stalls.
   - `[MINOR]` — reviewer will nit but merge if rest is clean.
   - `[INFO]` — informational; no action required.
5. **Write findings to** `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`
   in this format:

   ```markdown
   context: subagent
   model: inherit

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

The `N blocking` token is machine-parsed by statusreport
(`failed_redteam`, regex `\d+\s+blocking`) — never reword it; the old
template vocabulary ("N block") is invisible to that parser.

The format above is contract: `statusreport.sh` parses for the word
`blocking` and an integer to surface failed red-teams in status
reports per spec §14.4.

## Templates referenced

- the resolved `redteam_mr.md` (§12 registry: project paths → devdoc → plugin default) — the adversarial prompt itself.
