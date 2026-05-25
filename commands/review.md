---
description: Run code review on the active issue's branch. Wraps superpowers:requesting-code-review.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:review

Step 13 of the 21-step devAgent workflow. Invokes the upstream
`superpowers:requesting-code-review` skill against the issue's
branch diff. Produces a review report that the operator addresses
before the red-team step (14).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists (proves draftmr ran) and branch is set.
3. Resolve coding_standards artifact per spec §12 and pass its path
   to the wrapped skill as context.
4. Invoke `superpowers:requesting-code-review` with the diff scope
   = `baseline_sha..HEAD` on the issue's branch.
5. Save the review output to `<issue-dir>/analysis/YYYY-MM-DD-review.md`.
6. Log:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" review \
     "Review: F findings (B blocking, N nits); see analysis/YYYY-MM-DD-review.md; note: $NOTE"
   ```

## Halt and ask if

- mr.md does not exist (draftmr step skipped).
- The wrapped skill returns blocking findings — do not silently
  advance. Surface the findings and let the operator decide whether
  to address, mark `[!]` stuck, or override.

## Skipping policy

Never auto-skip; review is a quality gate.

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
