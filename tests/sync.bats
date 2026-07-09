#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Pretend Issue-1 was shipped and has an MR URL stored.
    # Insert mr_url before [parked] so it is a top-level TOML key.
    sed -i 's|\[parked\]|mr_url = "https://github.com/acme/testproj/pull/77"\n[parked]|' \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Mark step 15 done so sync considers this issue.
    sed -i 's|^- \[ \] 15. ship.*|- [x] 15. ship|' "$DEVDOC_DIR/Issue-1/checklist.md"

    # Stub code/github.sh mr-state to return "merged".
    mkdir -p "$DEVAGENT_TMP/fake-code"
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<EOF
#!/usr/bin/env bash
echo "code/github \$@" >> "$DEVAGENT_STUB_LOG"
[ "\$1" = "mr-state" ] && echo merged
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    export DEVAGENT_CODE_BACKEND_DIR="$DEVAGENT_TMP/fake-code"

    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "sync.sh detects merged MR and fires on_merge transition" {
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "code/github mr-state https://github.com/acme/testproj/pull/77"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_merge"
    grep -q 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "sync.sh fail-closes the on_merge transition when transition_issue is off (#219)" {
    # Default test config sets transition_issue=true; turn it off for this project.
    sed -i 's|^transition_issue *=.*|transition_issue = false|' "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    # The merge is still detected (mr-state queried) ...
    devagent_assert_logged "code/github mr-state https://github.com/acme/testproj/pull/77"
    # ... but NO remote transition is fired without the gate.
    devagent_refute_logged "transition"
    # The operator is told why.
    [[ "$output" == *"transition_issue"* ]]
    # And the idempotence marker is NOT written, so enabling the gate later still fires.
    run grep 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "sync.sh skips issues whose MR is still open" {
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "mr-state" ] && echo open
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_refute_logged "on_merge"
}

@test "sync.sh --all iterates every configured project" {
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.other]
source_dir       = "$DEVAGENT_TMP/src/other"
devdoc_dir       = "$DEVAGENT_TMP/devdoc/other"
default_baseline = "origin/main"
all_prs_branch   = "dev/all-prs"
branch_prefix_map = { bug = "fix", feature = "feat" }

[project.other.permissions]
push_mr = true
merge_to_all_prs = true
commit_devdoc = false
transition_issue = true
cleanup_on_merge = false

[project.other.issue_source]
backend = "github"
repo    = "acme/other"
dir_prefix = "Issue-"

[project.other.code_source]
backend  = "github"
upstream = "acme/other"
fork     = "me/other"

[project.other.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
EOF
    # #107/F7: give 'other' a SHIPPED issue too, so --all has real per-project
    # work — otherwise the test passes even when --all iterates ZERO projects.
    mkdir -p "$DEVAGENT_TMP/devdoc/other/Issue-1"
    printf -- '- [x] 15. ship\n\n## Log\n' > "$DEVAGENT_TMP/devdoc/other/Issue-1/checklist.md"
    cat > "$HOME/.claude/devagent/state/other.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$DEVAGENT_TMP/devdoc/other/Issue-1"
mr_url = "https://github.com/acme/other/pull/88"
branch = ""

[parked]
EOF
    run "$DEVAGENT_ROOT/scripts/sync.sh" --all
    [ "$status" -eq 0 ]
    # --all must process EVERY configured project — assert the per-project
    # mr-state call for both, not merely rc 0 (the old vacuous assertion).
    devagent_assert_logged "code/github mr-state https://github.com/acme/testproj/pull/77"
    devagent_assert_logged "code/github mr-state https://github.com/acme/other/pull/88"
}

@test "sync.sh --all continues past a project whose mr-state fails (#141)" {
    # Second project, also shipped with an mr_url.
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.other]
source_dir       = "$DEVAGENT_TMP/src/other"
devdoc_dir       = "$DEVAGENT_TMP/devdoc/other"
default_baseline = "origin/main"
all_prs_branch   = "dev/all-prs"
branch_prefix_map = { bug = "fix", feature = "feat" }

[project.other.issue_source]
backend = "github"
repo    = "acme/other"
dir_prefix = "Issue-"

[project.other.code_source]
backend  = "github"
upstream = "acme/other"
fork     = "me/other"

[project.other.issue_workflow]
on_merge = "Done"
EOF
    mkdir -p "$DEVAGENT_TMP/devdoc/other/Issue-1"
    printf -- '- [x] 15. ship\n\n## Log\n' > "$DEVAGENT_TMP/devdoc/other/Issue-1/checklist.md"
    cat > "$HOME/.claude/devagent/state/other.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$DEVAGENT_TMP/devdoc/other/Issue-1"
mr_url = "https://github.com/acme/other/pull/88"
branch = ""

[parked]
EOF
    # Make EVERY mr-state call FAIL (network/auth-style). The call is still
    # logged before the non-zero exit. Order-independent: pre-fix the first
    # project's failure aborts the loop so the second is never reached.
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<EOF
#!/usr/bin/env bash
echo "code/github \$@" >> "$DEVAGENT_STUB_LOG"
[ "\$1" = "mr-state" ] && { echo "mr-state: boom" >&2; exit 1; }
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    run "$DEVAGENT_ROOT/scripts/sync.sh" --all
    [ "$status" -eq 0 ]
    # Both projects were attempted despite the mr-state failures.
    devagent_assert_logged "code/github mr-state https://github.com/acme/testproj/pull/77"
    devagent_assert_logged "code/github mr-state https://github.com/acme/other/pull/88"
    # and the per-project failure is surfaced, not swallowed.
    [[ "$output" == *"mr-state failed"* ]]
}

@test "sync.sh detects a MERGED (uppercase) state — github mr-state returns uppercase (#43)" {
    # `gh pr view --json state` (via code/github.sh mr-state) returns "MERGED",
    # not "merged"; sync must compare case-insensitively.
    cat > "$DEVAGENT_CODE_BACKEND_DIR/github.sh" <<EOF
#!/usr/bin/env bash
echo "code/github \$@" >> "$DEVAGENT_STUB_LOG"
[ "\$1" = "mr-state" ] && echo MERGED
EOF
    chmod +x "$DEVAGENT_CODE_BACKEND_DIR/github.sh"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/testproj 1 on_merge"
    grep -q 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "sync.sh fires on_merge for a re-shipped revision despite revision 1's stale sync marker (#318)" {
    # Post-revise: revision 1 shipped and synced (marker in ## Log), revision 2
    # re-shipped. The file-wide idempotence grep matched revision 1's stale marker
    # and suppressed revision 2's merge forever. Revision-scoped read must fire.
    cat > "$DEVDOC_DIR/Issue-1/checklist.md" <<'EOF'
# Issue-1 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x] 15. ship
- [x] 20. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
- 2026-05-19 15:00  sync: Issue-1 merged → on_merge fired
- 2026-05-19 16:00  revise: revision 2 started, 2 comments to address

## Revision 2

- [ ]  1. draft
- [x] 15. ship
- [ ] 20. cleanup
EOF
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition acme/testproj 1 on_merge"
    # A FRESH marker was appended (rev-1's seeded marker + the new one = 2),
    # proving the fire logged its own idempotence marker past the revise boundary.
    [ "$(grep -c 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md")" -eq 2 ]
    # Exactly once: a SECOND sync must not re-fire (marker now after the boundary).
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    run bash -c "grep -c 'transition acme/testproj 1 on_merge' '$DEVAGENT_STUB_LOG'"
    [ "$output" -eq 1 ]
}

@test "sync.sh does not fire on_merge while the active revision is unshipped (#318)" {
    # Revision 1 shipped (historical [x] 15); operator revised to revision 2, not
    # yet shipped. A merged mr-state must NOT fire — the file-wide ship grep
    # matched revision 1's [x] 15 and fired prematurely.
    cat > "$DEVDOC_DIR/Issue-1/checklist.md" <<'EOF'
# Issue-1 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x] 15. ship

## Log
- 2026-05-19 14:00  pull: fixture seed
- 2026-05-19 16:00  revise: revision 2 started, 1 comments to address

## Revision 2

- [ ]  1. draft
- [ ] 15. ship
EOF
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_refute_logged "on_merge"
}
