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
    devagent_fixture_projB
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.projB.permissions]
transition_issue = true

[project.projB.issue_source]
backend    = "github"
repo       = "acme/projB"
dir_prefix = "Issue-"
EOF

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

# ---- #710: the transition writes the configured mapping ----

# _real_github_backend: the REAL issue/github.sh against the stub gh, so the
# assertion lands at gh's boundary (the argv of `gh issue edit`), not at a
# verb-logging stub. No DEVAGENT_PROJECT is exported (hermetic-env unsets it).
_real_github_backend() {
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_ROOT/scripts/issue"
    mkdir -p "$DEVAGENT_TMP/ghbin"
    cp "$DEVAGENT_ROOT/tests/fixtures/gh-stub" "$DEVAGENT_TMP/ghbin/gh"
    chmod +x "$DEVAGENT_TMP/ghbin/gh"
    export PATH="$DEVAGENT_TMP/ghbin:$PATH"
    export GH_STUB_ARGV_LOG="$DEVAGENT_TMP/gh-argv"
    : > "$GH_STUB_ARGV_LOG"
    export GH_STUB_REPO_LABELS='[{"name":"In Progress"},{"name":"In Review"},{"name":"Done"}]'
}

@test "draft start passes the resolved project to the backend (#710)" {
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/testproj 1 on_draft_start --project testproj"
}

@test "draft start runs the real github backend: the mapped label lands at the gh boundary (#710)" {
    _real_github_backend
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -qxF '[issue] [edit] [1] [--repo] [acme/testproj] [--add-label] [In Progress]' "$GH_STUB_ARGV_LOG"
}

@test "draft start with ambient DEVAGENT_PROJECT=<other> uses the resolved project's mapping (#710)" {
    _real_github_backend
    printf '%s\n' '' '[project.other.issue_workflow]' 'on_draft_start = "WRONG"' \
        >> "$HOME/.claude/devagent/config.toml"
    DEVAGENT_PROJECT=other run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -qxF '[issue] [edit] [1] [--repo] [acme/testproj] [--add-label] [In Progress]' "$GH_STUB_ARGV_LOG"
    run grep -F 'WRONG' "$GH_STUB_ARGV_LOG"
    [ "$status" -eq 1 ]
}

@test "draft start warns with the exit code when the label is missing, and exits 0 (#710)" {
    _real_github_backend
    export GH_STUB_REPO_LABELS='[{"name":"In Review"},{"name":"Done"}]'
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"github.sh: label 'In Progress' (on_draft_start) not found on acme/testproj"* ]]
    [[ "$output" == *"warning: on_draft_start transition failed for testproj/Issue-1 (exit 4) — continuing per spec §11"* ]]
    run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
    [ "$status" -eq 1 ]
}

@test "draft start with no issue tracker skips, Issue and Issue-Fork legs (#710)" {
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.issue_source"
    run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft: no issue tracker configured for Issue-1; skipping on_draft_start transition"* ]]
    DEVAGENT_ACTIVE_ISSUE=Issue-Fork-3 run "$DEVAGENT_ROOT/scripts/transition-draft-start.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft: no issue tracker configured for Issue-Fork-3; skipping on_draft_start transition"* ]]
    devagent_refute_logged "transition"
}
