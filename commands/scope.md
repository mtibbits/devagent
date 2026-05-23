---
description: Run six-question scope evaluation on the active issue's plan. Invokes devagent-scope skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:scope

Step 2 of the 21-step devAgent workflow. Invokes the `devagent-scope`
skill to walk through six structured questions and append a
`## Scope evaluation` section to `<issue-dir>/imPlan.md`.

## Argument parsing

Identical to `/devagent:draft`. See `commands/draft.md` for the full
spec §6.1 grammar. In one sentence: optional `project`, optional
`Issue[-Fork]-N`, the rest is `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `<issue-dir>/imPlan.md` exists. If not, halt: operator must
   run `/devagent:draft` first.
3. Invoke the `devagent-scope` skill with `$ISSUE_DIR=<issue-dir>`
   and `$NOTE` as user intent.
4. The skill appends `## Scope evaluation` to `imPlan.md`.
5. The skill itself appends the log entry via
   `scripts/checklist-log.sh`.

## Halt and ask if

- `imPlan.md` is missing (run draft first).
- A `## Scope evaluation` section already exists (overwrite? new
  sub-section? abort?).

## Skipping policy

Never auto-skip. If the issue is a trivial typo and the six questions
don't apply, surface the skip request to the operator rather than
silently advancing.
