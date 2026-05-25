---
name: core-redmr
description: Use when running step 14 of the devAgent workflow to run a red-team adversarial review of the MR body and diff before shipping upstream
when-to-use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
---

# devagent-redmr

Step 14 of the devAgent 21-step workflow. Runs the project's MR
red-team prompt (`templates/redteam_mr.md`, resolved per §12 registry)
against `<issue-dir>/mr.md` plus the branch diff. Produces a severity-
classified findings report and refuses to silently advance past
blocking findings.

## Overview

Red-team is adversarial: assume the reviewer is hostile and looking
for any reason to reject. The output is a list of findings classified
by severity. The operator must address every BLOCKING finding before
the ship step will fire.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/mr.md` (the MR body under attack).
  - `<issue-dir>/imPlan.md`, `actualWork.md` (for context).
  - `git diff <baseline_sha>..HEAD` (the actual code change).
  - Resolved `templates/redteam_mr.md` (per spec §12 registry).
- Writes: `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

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
6. **Refuse silent advance.** If B > 0, the skill exits with a
   non-zero status indicator and explicitly tells the operator to
   address findings before re-running, or mark `[!]` stuck via
   `/devagent:stuck`.

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
scripts/checklist-log.sh "$ISSUE_DIR" redmr \
  "Red-team: B blocking, M major, m minor, I info (template: $TEMPLATE_PATH); note: $NOTE"
```

The format above is contract: `statusreport.sh` parses for the word
`blocking` and an integer to surface failed red-teams in status
reports per spec §14.4.

## Templates referenced

- `templates/redteam_mr.md` (the adversarial prompt itself).

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
Return control to the operator with a one-line summary of what was
written and which step is next on the checklist.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then after stopping, invoke that exact CHAIN: command verbatim to
continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO NOT chain. Pause and wait for explicit
instruction even if your internal TODO list still has steps after
this one — the operator's last explicit instruction is the
authoritative scope.
