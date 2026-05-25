---
name: core-document-actual-work
description: Use when running step 9 of the devAgent workflow to record what was actually built versus what was planned, terse when there is no deviation from the plan
when-to-use: After /devagent:quality and before /devagent:commit. Run as part of /devagent:document.
---

# devagent-document-actual-work

Step 9 of the devAgent 21-step workflow. Writes
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
- Writes: creates `<issue-dir>/actualWork.md` from
  `templates/actualWork_template.md`.

## Checklist

1. **Compare plan to diff.** For each task in `imPlan.md`, find the
   commit(s) that implemented it. Mark each task as
   `[done as planned]`, `[done with deviation: <one-line reason>]`,
   `[skipped: <reason>]`, or `[discovered: <one-line description>]`
   for work done that wasn't in the plan.
2. **No deviation = terse.** If every task is `[done as planned]`,
   the actualWork.md is exactly this:

   ```markdown
   # Issue-NNNN — Actual work

   Plan executed as written. See `imPlan.md` for tasks; see
   `git log <baseline>..HEAD` for commits.
   ```

   No further sections. No "summary of what was built". No filler.

3. **Deviation = explain.** For each `[deviation]`, `[skipped]`, or
   `[discovered]`, write one paragraph under a `## Deviations` heading:
   what changed, why, what the operator should know later.

4. **Follow-ups.** Any `[discovered]` items that suggest future work
   get a `### Follow-up` sub-heading (the `/devagent:reap` skill
   harvests these by exactly this heading).

## Output template (deviation case)

```markdown
# Issue-NNNN — Actual work

## Plan vs actual
- Task 1: [done as planned]
- Task 2: [done with deviation: boundary test extended to cover
  negative n after discovering related bug]
- Task 3: [discovered: foo_kernel callers in bar.c had matching
  off-by-one; not fixed here per surgical-diffs principle]

## Deviations
### Task 2 deviation
The plan called for a single boundary test at n=N. While writing it,
n=-1 also failed the assertion. Extended to cover that case.

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

## Skipping policy

Never auto-skip. This is the **only** place deviations get documented;
skipping defeats the purpose. If the operator insists on skipping,
surface that this means no record of what was actually built.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" document \
  "actualWork.md written: D deviations, F follow-ups; note: $NOTE"
```

## Templates referenced

- `templates/actualWork_template.md` (canonical structure with
  Deviations and Follow-up sub-headings).

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
