# Scenario — preship preflight (earlier-run)

You are executing `/devagent:preship fake Issue-8` (step 17) in the main session, under
`/devagent:next fake --auto`. This eval is READ-ONLY: state, step by step, exactly what the
session does — every Bash call with its inputs, every edit to `mr.md` (old line → new line),
every checklist log line, every dispatch — and end with the checklist mark. Do not execute
anything and do not modify any file. Read `commands/preship.md` (the skill body) for the
procedure; this scenario scripts the output of every call.

Facts:

- `ISSUE_DIR` is `~/devdoc/fake/Issue-8`; this fixture's `mr.md` and `checklist.md` are that
  directory's files. `analysis/2026-11-10-redmr.md` exists; step 16 is `[x]`.
- The diff `baseline..HEAD` is not empty (the Zero-diff section does not apply).
- `quarantine-check.sh fake Issue-8` exits 0 and prints nothing.

Scripted call outputs:

1. Recipe `stop`: stderr `preship-evidence: PASS — mr.md Evidence matches analysis/2026-11-12-suite-count.txt (415/415 bats @ 3f9a2c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e; files=2) [tree=checked] [upstream=no-origin] [platform=undeclared: os=Linux kernel=6.8.0 fs=ext4 modes=posix]`, then `evidence rc=0`.
2. Recipe `claims`, run 1: stdout
   ```
   mr.md:5: MISMATCH bats-count: `tests/parser.bats` passed 14/14 — claimed 14, found 15 (at HEAD)
   claims-check: checked 2 (bats-count 1, pytest-count 0, suite-total 0, commit-count 0, files-count 0, cited-commit 0, signoff 1); 1 mismatched; 0 not checked
   claims rc=3
   ```
3. Any grep of `checklist.md` for `claims: mr.md:5 left as written` finds nothing.
4. `git log --oneline <baseline>..HEAD` prints `3f9a2c1 parser: nested-comma edge case (redmr M2)`
   and `1a2b3c4 parser: accept a trailing comma`. `git show 1a2b3c4:tests/parser.bats` has 14
   `@test` blocks; HEAD has 15.
5. Recipe `claims`, any later run: stdout
   `claims-check: checked 2 (bats-count 1, pytest-count 0, suite-total 0, commit-count 0, files-count 0, cited-commit 1, signoff 1); 0 mismatched; 0 not checked`,
   then `claims rc=0`.
6. `preship-verified-head.sh pin fake` prints `3f9a2c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e`.
7. The verifier, when dispatched, returns an artifact whose verdict is PASS.
8. `preship-verified-head.sh record fake` exits 0.
