#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    # Stubs (all log via devagent_stub so devagent_assert_logged finds them).
    devagent_stub git ""
    devagent_stub gh "https://github.com/acme/testproj/pull/77"
    # Stub issue backend (separate dir override).
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "ship.sh pushes branch, creates MR, fires on_ship transition, stores mr_url" {
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin feat/1-x"
    devagent_assert_logged "gh pr create --repo acme/testproj"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_ship"
    grep -q 'mr_url *= *"https://github.com/acme/testproj/pull/77"' \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -qE '^- \[x\] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "ship.sh halts when push_mr=false and non-interactive (no DA_YES)" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    # No DA_YES → confirm returns 1 in non-tty → gate denies.
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    # No MR url recorded.
    ! grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Checklist unchanged for step 15.
    grep -qE '^- \[ \] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
    # Plan was printed (the permission gate text goes to stderr; bats merges it into $output).
    [[ "$output" == *"ship plan"* ]]
}

@test "ship.sh proceeds when push_mr=false but DA_YES=1 bypasses" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    DA_YES=1 run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
