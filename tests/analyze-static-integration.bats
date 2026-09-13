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

# Shared by the #591 tests below. Every external tool is skipped — no
# linter/sanitizer deps; these tests assert the analyzer's scope detection, not
# its findings.
SKIP_TOOLS="cppcheck cpplint clang-tidy iwyu clang-format codespell cmake-lint ruff flake8 bandit mypy scan-build compiler asan tsan"

# Commit a README change on top of the fixture's current HEAD and leave $base at
# the pre-change commit, so base..working-tree carries one tracked hunk.
commit_readme_change() {
    base="$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    printf 'line1\nline2_changed\n' > "$SOURCE_DIR/README.md"
    ( cd "$SOURCE_DIR" && git add README.md && git commit -q -m "change README" )
}

# Run the REAL analyzer from a foreign CWD (the #53 regression condition) against
# $SOURCE_DIR at $base with build dir $1; any further args pass through.
run_static_analyzer() {
    local build_dir="$1"; shift
    cd "$DEVAGENT_TMP" || return 1
    run python3 "$DEVAGENT_ROOT/static_analysis_diff.py" \
        --repo "$SOURCE_DIR" "$base" "$build_dir" "$@" --skip $SKIP_TOOLS
}

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

@test "static_analysis_diff.py: an untracked source file enters scope with a whole-file range (#591)" {
    commit_readme_change
    # NEVER `git add`-ed — the #591 gap. Three lines, so a line-1-only range fails.
    printf 'x = 1\ny = 2\nz = 3\n' > "$SOURCE_DIR/new.py"
    run_static_analyzer "$SOURCE_DIR/build"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Untracked files (whole-file scope): new.py"* ]]
    [[ "$output" == *"new.py: lines 1-3"* ]]
    [[ "$output" == *"Changed files: README.md, new.py"* ]]
}

@test "static_analysis_diff.py: the untracked notice reaches STDOUT so analyze-static.sh tees it (#591)" {
    # The capture red-team's Q1: a stderr-only warning is how this gap survived,
    # and bats' `run` MERGES the streams — a combined-output assertion cannot tell
    # them apart. Capture stdout alone, exactly as the #119 test does.
    commit_readme_change
    printf 'x = 1\n' > "$SOURCE_DIR/new.py"
    cd "$DEVAGENT_TMP"
    run bash -c "python3 '$DEVAGENT_ROOT/static_analysis_diff.py' --repo '$SOURCE_DIR' '$base' '$SOURCE_DIR/build' --skip $SKIP_TOOLS 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Untracked files (whole-file scope): new.py"* ]]
}

@test "static_analysis_diff.py: an unreadable untracked candidate's warning reaches STDOUT (#591)" {
    # redmr 2026-09-06 MAJOR: the skip warning went to stderr ALONE, which
    # analyze-static.sh does not tee — the one place the sweep drops a candidate
    # was invisible in the artifact. A dangling symlink is a candidate git lists
    # that read_bytes() cannot open. Same stdout-only capture as the test above.
    commit_readme_change
    ln -s missing.py "$SOURCE_DIR/dangling.py" 2>/dev/null \
        || skip "ln -s not permitted on this host"
    printf 'x = 1\n' > "$SOURCE_DIR/seen.py"
    cd "$DEVAGENT_TMP"
    run bash -c "python3 '$DEVAGENT_ROOT/static_analysis_diff.py' --repo '$SOURCE_DIR' '$base' '$SOURCE_DIR/build' --skip $SKIP_TOOLS 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Untracked files (whole-file scope): seen.py"* ]]   # positive control
    [[ "$output" == *"skipping unreadable untracked candidate: dangling.py"* ]]
}

@test "static_analysis_diff.py: a gitignored untracked file stays out of scope (#591)" {
    printf 'ignored.py\n' > "$SOURCE_DIR/.gitignore"
    ( cd "$SOURCE_DIR" && git add .gitignore && git commit -q -m gitignore )
    commit_readme_change
    printf 'x = 1\n' > "$SOURCE_DIR/ignored.py"
    printf 'y = 2\n' > "$SOURCE_DIR/seen.py"
    run_static_analyzer "$SOURCE_DIR/build"
    [ "$status" -eq 0 ]
    # POSITIVE CONTROL FIRST: without it, "ignored.py is absent" is satisfied by
    # an enumeration that found nothing at all (register: Issue-337).
    [[ "$output" == *"seen.py"* ]]
    [[ "$output" != *"ignored.py"* ]]
}

@test "static_analysis_diff.py: --files does not widen scope to untracked files outside it (#591)" {
    commit_readme_change
    printf 'x = 1\n' > "$SOURCE_DIR/new.py"
    run_static_analyzer "$SOURCE_DIR/build" --files README.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"README.md: lines"* ]]   # the run produced scope; not empty
    [[ "$output" != *"new.py"* ]]
}

@test "static_analysis_diff.py: the analyzer's own build dirs are excluded from untracked scope (#591)" {
    commit_readme_change
    # bd is the build_dir passed below; bd-{asan,ubsan,tsan} are its derived
    # siblings; build-x-y/ is the sanitizer script's ROOT-level convention
    # (#324/#351) that an operator-configured build_dir would NOT derive
    # (improve bug 1); builder/ (no hyphen) must SURVIVE — not the bare build*/ proxy.
    mkdir -p "$SOURCE_DIR/bd" "$SOURCE_DIR/bd-asan" "$SOURCE_DIR/bd-ubsan" \
             "$SOURCE_DIR/bd-tsan" "$SOURCE_DIR/build-x-y" "$SOURCE_DIR/builder"
    for d in bd bd-asan bd-ubsan bd-tsan build-x-y; do
        printf 'g = 1\n' > "$SOURCE_DIR/$d/gen.py"
    done
    printf 'k = 3\n' > "$SOURCE_DIR/builder/kept.py"
    printf 'y = 2\n' > "$SOURCE_DIR/seen.py"
    [ ! -e "$SOURCE_DIR/.gitignore" ]   # the exclusion is NOT gitignore's doing
    run_static_analyzer "$SOURCE_DIR/bd"
    [ "$status" -eq 0 ]
    [[ "$output" == *"seen.py"* ]]           # positive control
    [[ "$output" == *"builder/kept.py"* ]]   # the hyphen-less dir survives
    [[ "$output" != *"gen.py"* ]]
}

@test "static_analysis_diff.py: a tracked-only tree prints no untracked notice (#591)" {
    commit_readme_change
    run_static_analyzer "$SOURCE_DIR/build"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Changed files: README.md"* ]]   # the run produced scope
    [[ "$output" != *"Untracked"* ]]
}
