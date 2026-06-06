#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Create a branch at HEAD with zero commits ahead — simulates artifact-only.
    local sha
    sha="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    ( cd "$SOURCE_DIR" && git checkout -q -b chore/1-baseline )
    # Set state as if branch.sh ran: branch set, baseline_sha = HEAD.
    sed -i "s|^branch *=.*|branch = \"chore/1-baseline\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"$sha\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Marker files (commit.sh reads these if it gets past the guard).
    echo "chore" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "baseline" > "$DEVDOC_DIR/Issue-1/.devagent-title"
}
teardown() { devagent_test_teardown; }

@test "commit.sh auto-skips on zero-diff branch" {
    # Clean tree + zero commits ahead → genuinely artifact-only, still skips.
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-marking step 10"* ]]
    grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q "auto-skipped.*no commits" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit.sh refuses to skip when the tree has uncommitted work (#25)" {
    # Real, in-scope work left in the working tree (the #87 untracked-file
    # case): zero commits ahead of baseline, but the tree is NOT empty. The
    # guard must fail loudly rather than auto-skip and ship an empty PR.
    echo "real implemented work" > "$SOURCE_DIR/newfile.txt"   # untracked
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"git add"* ]]
    # Must NOT have auto-marked the commit step as skipped.
    ! grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit.sh refuses to skip with modified-but-unstaged tracked work (#25)" {
    # The other dirty class: an existing tracked file edited but not 'git add'ed
    # (` M` in porcelain). Same die path via $dirty; assert it too.
    ( cd "$SOURCE_DIR" && echo "edit" >> README.md )          # tracked, unstaged
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"git add"* ]]
    ! grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh auto-skips on zero-diff branch" {
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-marking step 16"* ]]
    grep -qE '^\- \[-\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q "auto-skipped.*zero commits" "$DEVDOC_DIR/Issue-1/checklist.md"
}
