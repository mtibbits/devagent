---
name: core-impact
description: Use when running step 18 of the devAgent workflow to measure, quantify, and record the real-world impact of a merged change before extracting lessons learned
when_to_use: After /devagent:updatewbs (step 17) and before /devagent:lessonslearned (step 19). Run as part of /devagent:impact.
user-invocable: false
---

# devagent-impact

Step 18 of the devAgent 22-step workflow. Captures the *measurable*
outcome of a shipped change so future status reports, velocity
estimates, and lessons-learned have ground truth to refer to.

## Overview

A merged MR is not the same as impact. Impact is the answer to "what
changed in the world because this shipped?" — runtime improvement,
LOC reduction, bug fix verified in production, user complaint
silenced, etc. The skill writes `<issue-dir>/impact.md` with two
sections: **Quantifiable** (numbers) and **Qualitative** (when
numbers are not available or honest).

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/issue.md` (labels indicate the impact dimension to
    measure — `performance` → benchmarks; `bug` → reproducer fixed;
    `docs` → operator-facing clarity).
  - `<issue-dir>/actualWork.md`.
  - Pre/post evidence the operator points to (benchmark CSV, plot
    PNG from the project's evidence-plot script, etc.) — via `$NOTE`.
- Writes: `<issue-dir>/impact.md`.

## Checklist

1. **Read the issue labels.** Determine the impact dimension:
   - `performance` → speed-up percent, throughput delta.
   - `bug` → reproducer fixed; severity (crash/wrong-answer/cosmetic).
   - `docs` → operator-facing improvement (be honest: usually
     qualitative).
   - `chore`/`refactor` → LOC delta, maintainability score; usually
     qualitative.
2. **Quantifiable section.** For each measurable dimension, record:
   - Baseline number (with units, source, date).
   - Post-change number (same units, source, date).
   - Delta (absolute and percent).
   - Statistical context if available (N runs, std-dev, CI).
   - **Never invent numbers.** If a measurement was not run, say so
     explicitly: "Quantifiable measurement not run because <reason>;
     see Qualitative section."
3. **Qualitative section.** For impact that resists numbers:
   - What changed in user-visible behavior?
   - What complaint or follow-up issue does this close?
   - What downstream pattern does this enable / unblock?
4. **Evidence references.** Link or path-cite every artifact backing
   a quantifiable claim. If `$NOTE` includes a path to a plot PNG,
   embed the reference.
5. **Honesty check.** Re-read every quantifiable claim. If you cannot
   point to evidence, move it to Qualitative or strike it.

## Output format

```markdown
# Issue-NNNN — Impact

## Quantifiable
- Throughput on the target board: 1.84 GB/s → 2.31 GB/s (+25.5%, N=30, σ=0.04)
  evidence: evidence-plot output at
  <issue-dir>/evidence/<date>-<host>.png
- Build time: unchanged.

## Qualitative
- Unblocks fusion of post-processing stages (separate issue).
- Pattern documented for future stage-pair fusions.
```

## Halt and ask if

- Issue labels suggest performance impact but no benchmark evidence
  is supplied via `$NOTE` and none is discoverable in
  `<issue-dir>/analysis/` — surface "no evidence; halt or proceed
  qualitative-only?"
- Operator's $NOTE includes numbers that contradict observable
  evidence — surface the discrepancy rather than copying the note.

## Skipping policy

Never auto-skip. If a change has genuinely no measurable impact (pure
chore), surface "no impact to measure; mark step `[-]` skipped?" and
require operator confirmation. Default is not to skip — qualitative
notes still have value for lessons-learned.

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" impact \
  "impact.md written: Q quantifiable claims, L qualitative notes; note: $NOTE"
```

## Templates referenced

- None directly. References the project's evidence-plot outputs when
  performance evidence exists.
