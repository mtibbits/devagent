#!/usr/bin/env bats
# #532: the wired validate gate is NON-STRICT (rc=0 required). --strict is
# documented-red on the no-version policy (README §Versioning; decision doc
# devDoc Issue-532/decision-plugin-versioning.md). CI has no claude CLI, so
# this rung is local-only: it skips there; admissible evidence is a local
# non-skip run recorded in the issue's devDoc analysis dir.

@test "claude plugin validate (non-strict) passes at repo root (#532)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    run claude plugin validate "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]
}

# Inverse canary: the day --strict goes green without a version key, the
# documented-red rationale is obsolete and #532 should be revisited (wire the
# strict gate). Pins the MEASURED red (rc=1 + the version finding, 2.1.211) so
# a green here means "revisit #532" and any other drift (rc change, finding
# change, subcommand gone) also surfaces instead of passing as still-red.
@test "claude plugin validate --strict stays documented-red (#532)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    run claude plugin validate --strict "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 1 ]
    [[ "$output" == *version* ]]
}
