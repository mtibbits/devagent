---
description: Draft the MR body for the active issue. Invokes core-draft-mr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draftmr

Step 12 of the 21-step devAgent workflow. Invokes the
`core-draft-mr` skill to fill `templates/mr_template.md` from the
issue's artifacts and write `<issue-dir>/mr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify analyze step completed (`<issue-dir>/analysis/` exists).
3. Verify actualWork.md exists.
4. Invoke `core-draft-mr`. The skill calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- analyze step did not run (no analysis/ dir).
- actualWork.md missing.
- mr.md already exists with content (overwrite? revise? abort?).

## Skipping policy

Never auto-skip.
