---
description: Surface latent bugs, side effects, ambiguities in the active issue's plan. Invokes core-improve skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:improve

Step 3 of the 21-step devAgent workflow. Invokes the `core-improve`
skill to read `<issue-dir>/imPlan.md` and append an `## Improvements`
section flagging concrete defects.

## Argument parsing

Per `commands/draft.md`. In short: optional `project`, optional issue
dir, remainder = `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists AND contains a `## Scope evaluation`
   section. If not, halt and tell the operator to run scope first.
3. Invoke `core-improve` with `$ISSUE_DIR` and `$NOTE`.
4. The skill appends `## Improvements` and calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- Plan lacks `## Scope evaluation`.
- Plan already has an `## Improvements` section (overwrite? append
  sub-section? abort?).

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
