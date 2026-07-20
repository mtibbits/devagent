#!/usr/bin/env bats
# #532: the wired validate gate is NON-STRICT (rc=0 required). --strict is
# documented-red on the no-version policy (README §Versioning; decision doc
# devDoc Issue-532/decision-plugin-versioning.md). CI has no claude CLI, so
# this rung is local-only: it skips there and its admissible evidence is a
# local non-skip run (analysis/2026-07-20-validate-gate.txt).

@test "claude plugin validate (non-strict) passes at repo root (#532)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    run claude plugin validate "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]
}
