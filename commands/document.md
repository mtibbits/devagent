---
description: Record actual work versus the plan for the active issue. Invokes devagent-document-actual-work skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:document

Step 9 of the 21-step devAgent workflow. Invokes the
`devagent-document-actual-work` skill to write
`<issue-dir>/actualWork.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file has a `baseline_sha` (needed to diff actual
   against plan). If absent, halt — operator must run branch first.
3. Invoke `devagent-document-actual-work` with `$ISSUE_DIR` and
   `$NOTE`.
4. The skill writes actualWork.md and calls `scripts/checklist-log.sh`.

## Halt and ask if

- State file lacks `baseline_sha`.
- imPlan.md lacks `## Definition of done` section.

## Skipping policy

Never auto-skip; documenting deviations is the entire value of this
step.
