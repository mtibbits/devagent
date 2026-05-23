---
description: Run red-team adversarial review of the MR before shipping. Invokes devagent-redmr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:redmr

Step 14 of the 21-step devAgent workflow. Invokes the `devagent-redmr`
skill to run `templates/redteam_mr.md` against the MR body and diff,
classify findings by severity, and write the report to
`<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists.
3. Invoke `devagent-redmr`.
4. Skill writes the report and logs the finding counts in the
   parser-compatible format from spec §14.4. The skill itself calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- mr.md missing.
- Skill reports BLOCKING findings — do NOT advance to ship.

## Skipping policy

Never auto-skip; red-team is an unconditional gate per spec §6.3
principle and the operator's principal value prop.
