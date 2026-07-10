#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # #231/#242: a valid close requires the closeout steps terminal; mark
    # updatewbs/impact/lessonslearned [x] so the pre-existing cleanup tests
    # exercise the allowed path. Whitespace-robust: key on the line content,
    # edit the glyph in place (don't assume spacing).
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 17 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    ( cd "$DEVDOC_DIR" \
      && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com \
      && git config user.name Test \
      && git add . \
      && git commit -q -m "seed" )
    # Local main branch in source repo for the checkout.
    ( cd "$SOURCE_DIR" && git branch -f main )
}
teardown() { devagent_test_teardown; }

@test "cleanup.sh switches source tree to main, commits devdoc, clears active_issue" {
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "main" ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -ge 2 ]
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 x cleanup
}

@test "cleanup.sh skips devdoc commit when commit_devdoc=false" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}

@test "cleanup names the PINNED issue (not the shared slot) in the devdoc commit (#331)" {
    # Shared slot stays Issue-1; a pinned session cleans up Issue-2. The devdoc
    # commit message (from issue_arg) must name Issue-2 — before the fix issue_arg
    # was arg→SHARED state = Issue-1, naming the other session's issue.
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    msg="$( cd "$DEVDOC_DIR" && git log -1 --format='%s' )"
    [[ "$msg" == *"Issue-2"* ]]
    [[ "$msg" != *"Issue-1 cleanup"* ]]
}

@test "cleanup.sh commits an entirely-untracked (fresh) issue dir (#140)" {
    # A fresh Issue-2 dir created this cycle is fully untracked; with
    # commit_devdoc=true the auto-commit must still see it (the old tracked-only
    # diff guard was blind to untracked files).
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue "Issue-2"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" issue_dir "$DEVDOC_DIR/Issue-2"
    before=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -eq 0 ]
    after=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$after" -eq $((before + 1)) ]
    # the previously-untracked dir is now tracked and the tree is clean
    ( cd "$DEVDOC_DIR" && git ls-files --error-unmatch Issue-2/checklist.md )
    [ -z "$( cd "$DEVDOC_DIR" && git status --porcelain )" ]
}

@test "cleanup.sh reconciles the WBS leaf for the completed issue to [x]" {
    # Mark every step except step 20 done in the seeded checklist;
    # cleanup will mark step 20 itself, then call wbs update.
    sed -i 's/^- \[ \]\([ ]*\([0-9]*\)\.\)/- [x]\1/' \
        "$DEVDOC_DIR/Issue-1/checklist.md"
    # Re-mark step 20 as pending so cleanup has work to do.
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 ' '
    # Seed a WBS with the issue's leaf in-progress.
    cat > "$DEVDOC_DIR/WBS.md" <<EOF
# $TEST_PROJECT WBS

- [ ] Plan {est: 1w}
  - [~] Working leaf {issue: Issue-1, est: 1w}
EOF
    ( cd "$DEVDOC_DIR" && git add -A && \
        git -c user.email=t@x -c user.name=t commit -q -m "seed wbs" )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # cleanup marks its own step 20, then calls wbs update, which sees
    # all checklist lines [x] and flips the leaf to [x].
    grep -q "\[x\] Working leaf" "$DEVDOC_DIR/WBS.md"
}

@test "cleanup.sh soft-passes when no WBS.md exists (--if-exists)" {
    # No WBS.md in this fixture by default — cleanup should not fail
    # nor warn.
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"wbs reconcile failed"* ]]
}

@test "cleanup.sh clears per-issue keys (mr_url/baseline_sha/revision) (#98)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" mr_url "https://example.com/pr/9"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" baseline_sha "abc123"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set-int "$f" revision 3
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^mr_url = ""$' "$f"
    grep -qE '^baseline_sha = ""$' "$f"
    grep -qE '^revision = 1$' "$f"
    # Quoted "20" is deliberate: cleanup re-sets last_step via the string-typed
    # state_set AFTER the clear, preserving today's stored form exactly.
    grep -qE '^last_step = "20"$' "$f"
}

@test "cleanup.sh garbage-collects the issue's [context] snapshot (#98 review m4)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" context.Issue-1.branch "feat/1-x"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-1.branch
    [ "$status" -ne 0 ]
}

@test "cleanup.sh GCs the snapshot when \$2 is the issue-dir PATH (#98 redmr MIN-3)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" context.Issue-1.branch "feat/1-x"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-1"
    [ "$status" -eq 0 ]
    run python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-1.branch
    [ "$status" -ne 0 ]
}

@test "cleanup.sh blocks when lessonslearned is pending (#231)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' '
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *lessonslearned* ]]
    # fail-closed: no side effects — step 20 still pending, branch unchanged
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 ' ' cleanup
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]
}

@test "cleanup.sh proceeds when lessonslearned is skipped [-] (#231)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 '-'
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "cleanup.sh proceeds when the checklist has no lessonslearned step (#231)" {
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 19
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

# --- #242: generalized closeout gate ----------------------------------------

@test "cleanup dies naming ALL non-terminal closeout steps (#242)" {
    # Re-pend 17 and 18 (setup marked them [x]); 19 stays [x].
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 17 ' '
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 ' '
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"updatewbs:[ ]"* ]]
    [[ "$output" == *"impact:[ ]"* ]]
    # No side effect ran: step 20 unmarked, source repo still on the branch.
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 ' ' cleanup
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "feat/1-x" ]
}

@test "cleanup proceeds when closeout steps are [x]/[-] mixed (#242)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 17 '-'
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "cleanup: absent closeout steps do not gate (#242)" {
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 17
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 18
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 19
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "cleanup.sh removes the issue's keyed analyze build dirs, sparing siblings (#351)" {
    key="$(printf '%s-%s' "$TEST_PROJECT" "Issue-1" | tr -c 'A-Za-z0-9' '-')"
    mkdir -p "$SOURCE_DIR/build-$key" "$SOURCE_DIR/build-$key-asan" "$SOURCE_DIR/build-$key-tsan"
    # A different issue's dir whose key is a PREFIX (Issue-1 vs Issue-10) must survive.
    mkdir -p "$SOURCE_DIR/build-${TEST_PROJECT}-Issue-10-asan"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -d "$SOURCE_DIR/build-$key" ]
    [ ! -d "$SOURCE_DIR/build-$key-asan" ]
    [ ! -d "$SOURCE_DIR/build-$key-tsan" ]
    [ -d "$SOURCE_DIR/build-${TEST_PROJECT}-Issue-10-asan" ]   # prefix guard: not wiped
}
