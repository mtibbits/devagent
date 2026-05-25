---
description: Extract reusable lessons from a completed issue. Invokes core-lessons-learned skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:lessonslearned

Step 19 of the 21-step devAgent workflow. Invokes the
`core-lessons-learned` skill to write `<issue-dir>/lessonsLearned.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify checklist log has > 2 entries (otherwise nothing to learn from).
3. Invoke `core-lessons-learned`. The skill calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- Fewer than 2 log entries.
- lessonsLearned.md already exists with content (overwrite? append? abort?).

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
