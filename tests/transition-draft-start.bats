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
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.transition_issue" false
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

@test "#572: bare invocation with pointer on B and cwd in A refuses BEFORE the tracker call" {
    # projB: transition_issue=true AND a configured issue_source — without the
    # backend/repo fields the script skips at its unset-backend gate and leg (a)
    # would be degenerate (AC2 explicitly excludes the permission-skip rc 0).
    SRC_B="$DEVAGENT_TMP/src/projB"; DOC_B="$DEVAGENT_TMP/devdoc/projB"
    mkdir -p "$SRC_B" "$DOC_B/Issue-9"
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.projB]
source_dir = "$SRC_B"
devdoc_dir = "$DOC_B"

[project.projB.permissions]
transition_issue = true

[project.projB.issue_source]
backend    = "github"
repo       = "acme/projB"
dir_prefix = "Issue-"
EOF
    printf 'active_issue = "Issue-9"\nissue_dir = "%s/Issue-9"\n' "$DOC_B" \
      > "$HOME/.claude/devagent/state/projB.toml"
    printf 'active_project = "projB"\n' \
      > "$HOME/.claude/devagent/state/_active.toml"
    unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE

    # (a) NON-DEGENERACY: with the scope passed, the transition IS reached
    run bash -c "cd '$SOURCE_DIR' && '$DEVAGENT_ROOT/scripts/transition-draft-start.sh' projB"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/projB 9 on_draft_start"

    # (b) the bare invocation refuses at the guard, and the stub is NOT called
    : > "$DEVAGENT_STUB_LOG"
    run bash -c "cd '$SOURCE_DIR' && '$DEVAGENT_ROOT/scripts/transition-draft-start.sh'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SCOPE MISMATCH"* ]]
    devagent_refute_logged "transition"

    # (c) the enumerated caller's `|| true` semantics stay intact: the guarded
    # die is absorbed exactly like any other failure at that call shape
    run bash -c "cd '$SOURCE_DIR' && { '$DEVAGENT_ROOT/scripts/transition-draft-start.sh' || true; } && echo CALLER-CONTINUES"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CALLER-CONTINUES"* ]]
}

@test "draft start fires for the PINNED session issue, not the shared slot (#416)" {
    # Shared slot names Issue-1 (setup); a second session pinned to Issue-2 drafts.
    DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/testproj 2 on_draft_start"
    devagent_refute_logged "transition acme/testproj 1 on_draft_start"
}
