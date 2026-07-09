#!/usr/bin/env bats
# #325: on_draft_start must fire at the draft step's start, gated by
# permissions.transition_issue (fail-closed mirror of sync's on_merge, #219),
# and a transition failure must WARN not die (§11). Stub-backend pattern mirrors
# sync.bats.
load 'helpers/common'

setup() {
    devagent_test_setup
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "draft start fires exactly one on_draft_start when transition_issue=true (#325)" {
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/testproj 1 on_draft_start"
    # Exactly one — not zero, not a double-fire.
    run bash -c "grep -c 'transition acme/testproj 1 on_draft_start' '$DEVAGENT_STUB_LOG'"
    [ "$output" -eq 1 ]
}

@test "draft start fires no transition when transition_issue=false (#325)" {
    sed -i 's|^transition_issue *=.*|transition_issue = false|' "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_refute_logged "transition"
    [[ "$output" == *"transition_issue"* ]]
}

@test "draft start warns and proceeds when the transition fails (#325)" {
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"on_draft_start transition failed"* ]]
}
