---
name: core-document-actual-work
description: "Step 11: record what was actually built versus planned, terse when there is no deviation"
when_to_use: After /devagent:quality and before /devagent:commit. Run as part of /devagent:document.
user-invocable: false
---

# devagent-document-actual-work

Step 11 of the devAgent 24-step workflow. Writes
`<issue-dir>/actualWork.md` recording what was actually built. The
contract: **be terse when there is no deviation from `imPlan.md`**.
Most of the time, the plan is the work; the actualWork file is short.

## Overview

The plan answers "what should we build?" The actual-work file answers
"what did we build, and where did it differ?" Reviewers and future
operators read actualWork.md first when context-switching back to an
issue, so it must be honest about deviations.

The skill's bias is toward brevity. A plan that was executed
faithfully gets a 3-line actualWork.md — not a synthesised novel.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/imPlan.md` (the contract).
  - `git diff <baseline_sha>..HEAD` for the issue branch.
  - Per-task commit messages since baseline.
  - Resolved `actualWork_template.md` (per spec §12 registry: project paths →
    `<devdoc>/templates/` → plugin `${CLAUDE_PLUGIN_ROOT}/templates/actualWork_template.md`).
- Writes: creates `<issue-dir>/actualWork.md` from the resolved
  `actualWork_template.md` (§12; see Reads).

## Checklist

1. **Resolve template.** Walk the §12 artifact registry to find
   `actualWork_template.md` (project `[project.<name>.paths]` →
   `<devdoc>/templates/` → plugin default) — mirrors core-draft-mr. Use the
   resolved file as the structure for the actualWork.md this step writes; a
   project/devdoc override is honored, not silently bypassed.
2. **Compare plan to diff.** For each task in `imPlan.md`, find the
   commit(s) that implemented it. Mark each task — under `## Summary` —
   as `[done as planned]`, `[done with deviation: <one-line reason>]`,
   `[skipped: <reason>]`, or `[discovered: <one-line description>]`
   for work done that wasn't in the plan.
3. **No deviation = terse.** If every task is `[done as planned]`,
   the actualWork.md is exactly this:

   ```markdown
   # Actual Work — {{ISSUE_ID}}

   ## Summary
   Plan executed as written. See `imPlan.md` for tasks; see
   `git log <baseline>..HEAD` for commits.
   ```

   This is the canonical structure reduced to just `## Summary` — omit
   `## Deviations from plan`, `## Verification`, and `### Follow-up`. No
   "summary of what was built", no filler.

4. **Deviation = explain.** For each `[deviation]`, `[skipped]`, or
   `[discovered]`, write one paragraph under the template's
   `## Deviations from plan` heading: what changed, why, what the
   operator should know later.

5. **Follow-ups.** Any `[discovered]` items that suggest future work
   get a `### Follow-up` sub-heading (the `/devagent:reap` skill
   harvests bullets under exactly this heading). It is the **last**
   section — reap harvests until the next `### ` heading or end of
   file, so anything bulleted after it would be mis-harvested.

## Output template (deviation case)

Follows `actualWork_template.md` exactly: the per-task list lands in
`## Summary`, and `### Follow-up` is last (after `## Verification`).

```markdown
# Actual Work — {{ISSUE_ID}}

**Branch:** `{{BRANCH}}` based on `{{BASELINE_REF}}` (`{{BASELINE_SHA}}`)

## Summary
- Task 1: [done as planned]
- Task 2: [done with deviation: boundary test extended to cover
  negative n after discovering related bug]
- Task 3: [discovered: foo_helper callers in bar.c had matching
  off-by-one; not fixed here per surgical-diffs principle]

## Deviations from plan
### Task 2 deviation
The plan called for a single boundary test at n=N. While writing it,
n=-1 also failed the assertion. Extended to cover that case.

## Verification
- Build: clean
- Tests: 712/712

### Follow-up
- bar.c callers should be audited; file as separate issue per
  surgical-diffs.
```

## Halt and ask if

- The diff contains commits not attributable to any task in the plan
  AND not justifiable as "discovered" — surfaces possible scope creep.
- A planned task has no corresponding commit (was it really skipped?
  is the diff comparison broken?).
- The plan's Definition of done has unchecked items.

When the branch step (8) is absent from the issue's checklist (e.g. research),
there is no `baseline_sha` and no diff baseline — that is N/A and expected, not a
halt; document the work narratively instead of against a diff.

## Skipping policy

Never auto-skip. This is the **only** place deviations get documented;
skipping defeats the purpose. If the operator insists on skipping,
surface that this means no record of what was actually built.

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" document \
  "actualWork.md written: D deviations, F follow-ups; note: $NOTE"
```

## Templates referenced

- `actualWork_template.md`, resolved per the §12 registry (project paths →
  `<devdoc>/templates/` → plugin `${CLAUDE_PLUGIN_ROOT}/templates/actualWork_template.md`) (canonical structure with
  Deviations and Follow-up sub-headings).
