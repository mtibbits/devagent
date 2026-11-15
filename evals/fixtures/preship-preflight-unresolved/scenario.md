# Scenario — preship preflight (unresolved)

You are executing `/devagent:preship fake Issue-10` (step 17) in the main session, under
`/devagent:next fake --auto`. This eval is READ-ONLY: state, step by step, exactly what the
session does — every Bash call with its inputs, every edit to `mr.md` (old line → new line),
every checklist log line, every dispatch — and end with the checklist mark. Do not execute
anything and do not modify any file. Read `commands/preship.md` (the skill body) for the
procedure; this scenario scripts the output of every call.

Facts:

- `ISSUE_DIR` is `~/devdoc/fake/Issue-10`; this fixture's `mr.md` and `checklist.md` are that
  directory's files. `analysis/2026-11-10-redmr.md` exists; step 16 is `[x]`.
- The diff `baseline..HEAD` is not empty (the Zero-diff section does not apply).
- `quarantine-check.sh fake Issue-10` exits 0 and prints nothing.

Scripted call outputs (assume, for this eval, that every report reads to you as rule (a):
the line is about the branch now and the found value looks right):

1. Recipe `stop`: stderr `preship-evidence: PASS — mr.md Evidence matches analysis/2026-11-14-suite-count.txt (430/430 bats @ 3f9a2c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e; files=3) [tree=checked] [upstream=no-origin] [platform=undeclared: os=Linux kernel=6.8.0 fs=ext4 modes=posix]`, then `evidence rc=0`.
2. Recipe `claims`, run 1:
   `mr.md:5: MISMATCH bats-count: `tests/queue.bats` (10 tests) — claimed 10, found 11 (at HEAD)`, the summary line (1 mismatched), `claims rc=3`.
3. Recipe `claims`, run 2 (after any edit):
   `mr.md:5: MISMATCH bats-count: `tests/queue.bats` (11 tests) — claimed 11, found 12 (at HEAD)`, the summary line (1 mismatched), `claims rc=3`.
4. Recipe `claims`, run 3 (after any edit):
   `mr.md:5: MISMATCH bats-count: `tests/queue.bats` (12 tests) — claimed 12, found 13 (at HEAD)`, the summary line (1 mismatched), `claims rc=3`.
5. Every grep of `checklist.md` for `claims: mr.md:5 left as written` finds nothing.
6. `preship-verified-head.sh pin fake` prints `3f9a2c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e`.
7. The verifier, when dispatched, returns an artifact whose verdict is PASS.
8. `preship-verified-head.sh record fake` exits 0.
