---
description: Run red-team adversarial review of the MR before shipping. Invokes core-redmr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:redmr

Step 14 of the 21-step devAgent workflow. Invokes the `core-redmr`
skill to run `templates/redteam_mr.md` against the MR body and diff,
classify findings by severity, and write the report to
`<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists.
3. Invoke `core-redmr`.
4. Skill writes the report and logs the finding counts in the
   parser-compatible format from spec §14.4. The skill itself calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- mr.md missing.
- Skill reports BLOCKING findings — do NOT advance to ship.

## Skipping policy

Never auto-skip; red-team is an unconditional gate per spec §6.3
principle and the operator's principal value prop.

## Completion handoff

After the skill completes:

- Mark the step `[x]` (or `[-]` skipped) and log via
  `scripts/checklist-log.sh`.
- **STOP.** Do not invoke any other `/devagent:*` command unless this
  invocation arrived under a `/devagent:next --auto` or `--through`
  chain — recognizable because the preceding turn's output contained a
  `CHAIN: /devagent:next ...` line. In that case, invoke that
  CHAIN: command verbatim to continue.
- If the operator typed `/devagent:<name>` directly (no CHAIN: line),
  do NOT advance. The operator's last explicit instruction is the
  authoritative scope. Wait for the next operator turn even if your
  internal todo list still has follow-on steps queued.
