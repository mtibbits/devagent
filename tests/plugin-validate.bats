#!/usr/bin/env bats
# #532, re-taken at go-public (2026-09-18): plugin.json carries a semver
# `version`, so the wired validate gate is now the STRICT one (rc=0 required).
# Before 1.0.0 the policy was SHA-tracking with no version, --strict was
# documented-red on exactly that, and this file pinned the red. Decision doc:
# devDoc Issue-532/decision-plugin-versioning.md (2026-09-18 addendum). CI has
# no claude CLI, so this rung is local-only: it skips there; admissible
# evidence is a local non-skip run recorded in the issue's devDoc analysis dir.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

@test "claude plugin validate (non-strict) passes at repo root (#532)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    run claude plugin validate "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]
}

# The strict gate: warnings are errors. Measured rc=0 on 2.1.223 once
# plugin.json carried `version` (the only warning --strict raised before).
@test "claude plugin validate --strict passes at repo root (#532 re-take)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    run claude plugin validate --strict "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]
}

# The release tag's own preflight: plugin.json and the marketplace entry must
# agree on the version and the tag name must be the {name}--v{version} form
# Claude Code's dependency resolver reads. --force skips the dirty-tree and
# tag-exists checks (a checkout mid-edit is not a release); --dry-run creates
# nothing.
@test "claude plugin tag --dry-run resolves the devagent--v<version> tag (#532 re-take)" {
    command -v claude >/dev/null 2>&1 || skip "claude CLI not installed (CI)"
    local version
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
        "$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json")"
    run claude plugin tag --dry-run --force "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]
    [[ "$output" == *"devagent--v${version}"* ]]
}
