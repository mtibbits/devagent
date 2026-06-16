#!/usr/bin/env bats
# Integration test: runs the REAL static_analysis_diff.py (no fake-python stub)
# against a 2-commit fixture repo from a foreign CWD, asserting it resolves the
# target repo and reports a non-empty changed-line scope. Exercises the repo
# resolution (#53) + get_changed_ranges (#54) paths the fake-python stub in
# analyze-static.bats hides — the gap that let #53/#54 ship while the wrapper
# test "passed".
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "static_analysis_diff.py: real run from a foreign CWD reports non-empty changed-line scope" {
    # devagent_test_setup left $SOURCE_DIR as a git repo with one "init" commit.
    # Add a 2nd commit changing a tracked file so base..HEAD is non-empty.
    base="$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    printf 'line1\nline2_changed\n' > "$SOURCE_DIR/README.md"
    ( cd "$SOURCE_DIR" && git add README.md && git commit -q -m "change README" )

    # Skip every external tool — no linter/sanitizer deps; we assert the
    # analyzer's core scope detection, not its findings.
    skip_tools="cppcheck cpplint clang-tidy iwyu clang-format codespell cmake-lint ruff flake8 bandit mypy scan-build compiler asan tsan"

    # Run from a CWD that is NOT the target repo (the #53 regression condition).
    cd "$DEVAGENT_TMP"
    run python3 "$DEVAGENT_ROOT/static_analysis_diff.py" \
        --repo "$SOURCE_DIR" "$base" "$SOURCE_DIR/build" --skip $skip_tools

    [ "$status" -eq 0 ]
    # Non-empty changed-line scope: the fixture's changed file must be reported.
    [[ "$output" == *"Changed files: README.md"* ]]
    [[ "$output" == *"README.md: lines"* ]]
}

@test "static_analysis_diff.py: --json keeps progress off stdout so | jq works (#119)" {
    base="$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    printf 'line1\nline2_changed\n' > "$SOURCE_DIR/README.md"
    ( cd "$SOURCE_DIR" && git add README.md && git commit -q -m "change README" )

    skip_tools="cppcheck cpplint clang-tidy iwyu clang-format codespell cmake-lint ruff flake8 bandit mypy scan-build compiler asan tsan"

    cd "$DEVAGENT_TMP"
    # Capture STDOUT only — progress must have gone to stderr.
    run bash -c "python3 '$DEVAGENT_ROOT/static_analysis_diff.py' --json --repo '$SOURCE_DIR' '$base' '$SOURCE_DIR/build' --skip $skip_tools 2>/dev/null"
    [ "$status" -eq 0 ]
    # stdout must be a valid JSON document (no leading progress lines).
    echo "$output" | python3 -c 'import sys, json; json.load(sys.stdin)'
    # and must contain none of the progress text.
    [[ "$output" != *"Base ref:"* ]]
    [[ "$output" != *"Changed files:"* ]]
    [[ "$output" != *"Running"* ]]
}
