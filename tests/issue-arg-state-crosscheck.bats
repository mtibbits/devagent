#!/usr/bin/env bats
# Issue arg vs active-state cross-check (#70).
#
# ship.sh / commit.sh / mergetoall.sh accept an explicit issue arg ($2) used for
# tracker routing / commit-message {{issue}}, but issue_dir/branch/baseline come
# from state (the active issue). A mismatched explicit arg would operate on the
# active issue's branch while attributing the work to a different issue. Mirror
# the comments.sh/revise.sh guard: die on mismatch. The active-fallback path
# (no explicit arg) must remain unaffected.

load 'helpers/common'

setup() {
    devagent_test_setup
    # A second issue dir, so the explicit arg names a real-looking but
    # NON-active issue.
    mkdir -p "$DEVDOC_DIR/Issue-2"
    # Branch + markers as if /devagent:branch had run for the ACTIVE issue (1).
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b dev/all-prs \
      && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m "feat: x" )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "active work" > "$DEVDOC_DIR/Issue-1/.devagent-title"
}
teardown() { devagent_test_teardown; }

# --- commit.sh -------------------------------------------------------------

@test "commit.sh dies when explicit issue arg mismatches active state (#70)" {
    ( cd "$SOURCE_DIR" && echo more >> a.txt && git add a.txt )
    local before; before="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match"* ]]
    # Load-bearing: nothing was committed (HEAD unchanged) — died before commit.
    [ "$( cd "$SOURCE_DIR" && git rev-parse HEAD )" = "$before" ]
}

@test "commit.sh accepts the matching explicit issue arg (#70 no false-positive)" {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' '' 'Issue: {{issue}}' \
        > "$DEVDOC_DIR/templates/commit_template.md"
    ( cd "$SOURCE_DIR" && echo more >> a.txt && git add a.txt )
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    ( cd "$SOURCE_DIR" && git log -1 --pretty=%B ) | grep -q "Issue: Issue-1"
}

# --- mergetoall.sh ---------------------------------------------------------

@test "mergetoall.sh dies when explicit issue arg mismatches active state (#70)" {
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match"* ]]
}

# --- ship.sh ---------------------------------------------------------------

@test "ship.sh dies when explicit issue arg mismatches active state (#70)" {
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match"* ]]
    # Load-bearing: ship did not complete — step 15 is not marked done on the
    # active issue's checklist (it aborted at the cross-check, before push).
    run grep -qE '^- \[x\] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}
