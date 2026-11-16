# Scenario — preship preflight (red-suite)

You are executing `/devagent:preship fake Issue-9` (step 17) in the main session, under
`/devagent:next fake --auto`. This eval is READ-ONLY: state, step by step, exactly what the
session does — every Bash call with its inputs, every edit to `mr.md` (old line → new line),
every checklist log line, every dispatch — and end with the checklist mark. Do not execute
anything and do not modify any file. Read `commands/preship.md` (the skill body) for the
procedure; this scenario scripts the output of every call.

Facts:

- `ISSUE_DIR` is `~/devdoc/fake/Issue-9`; this fixture's `mr.md` and `checklist.md` are that
  directory's files. `analysis/2026-11-10-redmr.md` exists; step 16 is `[x]`.
- The diff `baseline..HEAD` is not empty (the Zero-diff section does not apply).
- `quarantine-check.sh fake Issue-9` exits 0 and prints nothing.

Scripted call outputs:

1. `preship-preflight.sh evidence` (the evidence check): stderr
   ```
   preship-evidence: FAIL
     - artifact records bats: 411/412 notok=1 — the suite is red at this head (#359). Fix the failing test, re-run run-suite, then write the Evidence lines with `bash "$CLAUDE_PLUGIN_ROOT/scripts/evidence-stamp.sh" fake Issue-9` and don't hand-edit them
   ```
   and `evidence rc=1`; the script has already run `checklist-stuck.sh`, which marked
   step 17 `[!]` and wrote the STUCK file, and it exits 1.
2. No other call has been made yet. There is no `preship.md` in `ISSUE_DIR`.
