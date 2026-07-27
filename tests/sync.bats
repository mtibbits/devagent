#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Pretend Issue-1 was shipped and has an MR URL stored.
    # Insert mr_url before [parked] so it is a top-level TOML key.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" mr_url "https://github.com/acme/testproj/pull/77"
    # Mark the ship step (18) done so sync considers this issue.
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 x

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
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.transition_issue" false
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
    printf -- '- [x] 18. ship\n\n## Log\n' > "$DEVAGENT_TMP/devdoc/other/Issue-1/checklist.md"
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
    printf -- '- [x] 18. ship\n\n## Log\n' > "$DEVAGENT_TMP/devdoc/other/Issue-1/checklist.md"
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
- [x] 18. ship
- [x] 23. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
- 2026-05-19 15:00  sync: Issue-1 merged → on_merge fired
- 2026-05-19 16:00  revise: revision 2 started, 2 comments to address

## Revision 2

- [ ]  2. draft
- [x] 18. ship
- [ ] 23. cleanup
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
- [x] 18. ship

## Log
- 2026-05-19 14:00  pull: fixture seed
- 2026-05-19 16:00  revise: revision 2 started, 1 comments to address

## Revision 2

- [ ]  2. draft
- [ ] 18. ship
EOF
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_refute_logged "on_merge"
}

# --- #363: sync unblocks + queues the closeout ------------------------------

@test "sync unblocks a [?] closeout step to [ ] on merge, logs it (#363)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 '?'
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 ' ' impact
    grep -q 'unblocked .* closeout step' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "sync prints CLOSEOUT nudge naming pending + the next command (#363)" {
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [[ "$output" == *"CLOSEOUT: $TEST_PROJECT/Issue-1 merged"* ]]
    [[ "$output" == *"pending:"* ]]
    [[ "$output" == *"run /devagent:next $TEST_PROJECT --auto"* ]]
}

@test "sync re-nudges on a second run w/o extra log lines; silent after cleanup (#363)" {
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [[ "$output" == *"CLOSEOUT:"* ]]
    local n1; n1="$(grep -c '  sync:' "$DEVDOC_DIR/Issue-1/checklist.md")"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"     # marker present now
    [[ "$output" == *"CLOSEOUT:"* ]]
    local n2; n2="$(grep -c '  sync:' "$DEVDOC_DIR/Issue-1/checklist.md")"
    [ "$n1" -eq "$n2" ]                                       # no extra log on marker-present path
    sed -i -E 's/^- \[ \] (19|2[0-3])\./- [x] \1./' "$DEVDOC_DIR/Issue-1/checklist.md"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [[ "$output" != *"CLOSEOUT:"* ]]                          # all closeout terminal → silent
}

@test "sync unblocks+nudges with transition_issue off; #219 preserved (#363)" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.transition_issue" false
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 '?'
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 ' ' impact
    [[ "$output" == *"CLOSEOUT:"* ]]                                       # nudged
    [[ "$output" == *"transition_issue"* ]]                               # #219 skip-warn
    run grep 'merged .* on_merge fired' "$DEVDOC_DIR/Issue-1/checklist.md" # marker NOT written
    [ "$status" -ne 0 ]
}

@test "sync leaves a NON-closeout [?] untouched (#363)" {
    # single-digit steps are space-aligned ("  7."), so match flexibly.
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 9 '?'
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 9 '?' implement
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 9 '?' implement
}

@test "sync does nothing (no CLOSEOUT) when the MR is still open (#363)" {
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "mr-state" ] && echo open
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"CLOSEOUT:"* ]]
}

@test "sync warns+skips on mr-state failure, checklist byte-identical (#363)" {
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "mr-state" ] && exit 1
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    before="$(md5sum "$DEVDOC_DIR/Issue-1/checklist.md")"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mr-state failed"* ]]
    after="$(md5sum "$DEVDOC_DIR/Issue-1/checklist.md")"
    [ "$before" = "$after" ]
}

@test "sync closeout flip lands in the ACTIVE revision block (#363)" {
    # Revision 1 (above ## Log) has closeout [x]; the active revision-2 block has [?].
    cat > "$DEVDOC_DIR/Issue-1/checklist.md" <<'CL'
# Issue-1 — checklist

- [x] 18. ship
- [x] 21. impact

## Log
- 2026-05-19 10:00  ship: MR
- 2026-05-19 11:00  revise: round 2

## Revision 2
- [x] 18. ship
- [?] 21. impact
CL
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    # The rev-1 line stays [x]; the active rev-2 line flips to [ ].
    grep -qE '^- \[x\] 21\. impact' "$DEVDOC_DIR/Issue-1/checklist.md"    # rev-1 untouched
    awk '/## Revision 2/{f=1} f && /21\. impact/{print}' "$DEVDOC_DIR/Issue-1/checklist.md" | grep -qE '^- \[ \] 21\. impact'
}

@test "sync.md carries the Closeout-handoff (CLOSEOUT) section (#363)" {
    grep -q 'Closeout handoff' "$DEVAGENT_ROOT/commands/sync.md"
    grep -q 'CLOSEOUT:' "$DEVAGENT_ROOT/commands/sync.md"
}

@test "sync re-unblocks a [?] closeout step set AFTER the merge marker (#421)" {
    # First sync writes the merge marker (marker-absent path fires on_merge).
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md"
    # A closeout step lands on [?] AFTER the marker (e.g. impact halted transiently).
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 '?'
    # The next sync takes the marker-PRESENT early-return path — it must still unblock.
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 ' ' impact
}
