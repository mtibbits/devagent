---
description: Measure and record the real-world impact of a merged change. Invokes core-impact skill.
argument-hint: "[project] [issue-dir] [free-form note: paths to evidence files]"
---

# /devagent:impact

Step 18 of the 21-step devAgent workflow. Invokes the `core-impact`
skill to write `<issue-dir>/impact.md`.

## Argument parsing

Per `commands/draft.md`. `$NOTE` is the conventional channel for
operator-supplied evidence paths (e.g.,
"benchmark plot at /abs/path/to/plot.png; baseline csv at /abs/path/baseline.csv").

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file shows the issue is merged (mr_url present and
   mr-state is `merged`). If not, halt — measuring impact on
   un-merged code is meaningless.
3. Invoke `core-impact` with `$ISSUE_DIR` and `$NOTE`.
4. Skill writes impact.md and calls `scripts/checklist-log.sh`.

## Halt and ask if

- Issue is not merged.
- Performance label present but no evidence path in `$NOTE`.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.

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
