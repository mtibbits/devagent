#!/usr/bin/env bats
# Integration tests for ship.sh #26 Defect-A pre-flight: fast-forward the stale
# fork base, hard-stop when the branch conflicts with upstream. Real git with
# local fork+upstream remotes; gh + issue backend stubbed (no network).
load 'helpers/common'

# Establish remotes, fork-first config, markers/mr, stubs. Each test then
# creates its own drift (C1 on origin) + issue branch (C2) before running ship.
setup() {
    devagent_test_setup
    UPSTREAM="$DEVAGENT_TMP/upstream.git"; FORK="$DEVAGENT_TMP/fork.git"
    git init -q --bare "$UPSTREAM"; git init -q --bare "$FORK"
    ( cd "$SOURCE_DIR"
      git remote add origin "$UPSTREAM"
      git remote add fork   "$FORK"
      git push -q origin main          # origin/main = C0
      git push -q fork   main          # fork/main   = C0
      git fetch -q origin; git fetch -q fork )
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.source_remote" "fork"
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.fork_first" true
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    echo "behind-upstream guard" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    devagent_stub gh "https://github.com/me/testproj/pull/99"
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

# Advance origin/main by one commit touching <file> with <content> (C1),
# WITHOUT touching fork/main → fork base becomes 1 behind upstream.
_advance_origin() {
    ( cd "$SOURCE_DIR" && git checkout -q main \
      && printf '%s\n' "$2" > "$1" && git add "$1" \
      && git -c user.email=u@e -c user.name=U commit -q -m "upstream $1" \
      && git push -q origin main )
}
# Cut issue branch feat/1-x from C0 and add a commit touching <file>/<content>.
_make_branch() {
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x origin/main~0 2>/dev/null || git checkout -q -b feat/1-x \
      ; printf '%s\n' "$2" > "$1" && git add "$1" \
      && git -c user.email=i@e -c user.name=I commit -q -m "issue $1" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
}

@test "ship FFs the stale fork base when branch is clean vs upstream" {
    # Branch cut from C0 first (so it does NOT contain C1), then origin advances.
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x main \
      && printf 'issue\n' > a.txt && git add a.txt \
      && git -c user.email=i@e -c user.name=I commit -q -m "issue a.txt" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    _advance_origin up.txt UPSTREAM_NEW          # C1 touches a different file → no conflict
    up_tip=$( cd "$SOURCE_DIR" && git rev-parse origin/main )

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # Fork base was fast-forwarded to the upstream tip.
    [ "$( git -C "$FORK" rev-parse main )" = "$up_tip" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 x ship
}

@test "ship hard-stops when the branch conflicts with upstream (no FF, no PR)" {
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x main \
      && printf 'ISSUE EDIT\n' > README.md && git add README.md \
      && git -c user.email=i@e -c user.name=I commit -q -m "issue README" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    fork_before=$( git -C "$FORK" rev-parse main )
    _advance_origin README.md UPSTREAM_EDIT       # C1 edits same file/line → conflict

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Rebase onto"* ]]
    # Fork base untouched; ship did not proceed to create a PR or mark step 18.
    [ "$( git -C "$FORK" rev-parse main )" = "$fork_before" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 ' ' ship
}

@test "ship hard-stops when the fork base has diverged (non-FF)" {
    # Issue branch off C0; clean vs upstream.
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x main \
      && printf 'issue\n' > a.txt && git add a.txt \
      && git -c user.email=i@e -c user.name=I commit -q -m "issue a.txt" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    # Diverge the fork base with a fork-ONLY commit off C0 (main still at C0),
    # BEFORE upstream advances — so neither is an ancestor of the other.
    ( cd "$SOURCE_DIR" && git checkout -q -b forktmp main \
      && printf 'forkonly\n' > forkonly.txt && git add forkonly.txt \
      && git -c user.email=f@e -c user.name=F commit -q -m "fork only" \
      && git push -q fork forktmp:main && git fetch -q fork )
    fork_div=$( git -C "$FORK" rev-parse main )
    # Now advance upstream off C0 (main is still at C0) → origin/main diverges from fork base.
    _advance_origin up.txt UPSTREAM_NEW

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]                                       # divergent base → hard-stop
    [[ "$output" == *"diverged"* ]]
    [[ "$output" == *"cannot be fast-forwarded"* ]]
    [ "$( git -C "$FORK" rev-parse main )" = "$fork_div" ]    # fork base untouched
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 ' ' ship
}

@test "fork_first=false leaves the pre-flight inert (no FF) despite drift" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.fork_first" false
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x main \
      && printf 'issue\n' > a.txt && git add a.txt \
      && git -c user.email=i@e -c user.name=I commit -q -m "issue a.txt" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    fork_before=$( git -C "$FORK" rev-parse main )
    _advance_origin up.txt UPSTREAM_NEW

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$( git -C "$FORK" rev-parse main )" = "$fork_before" ]   # no FF attempted
}

@test "fork_first stacked child skips the #26 pre-flight and bases on the parent (#34)" {
    # Stacked topology: main(C0) → feat/parent → feat/child. The parent edits README;
    # then origin/main advances editing README too. If #26 ran it would
    # branch_conflicts_upstream the CHILD (which contains the parent commit) against
    # origin/main → conflict → die. Because the child is stacked, #26 must be SKIPPED
    # and the PR based on feat/parent (whose currency vs upstream is irrelevant here).
    ( cd "$SOURCE_DIR"
      git checkout -q -b feat/parent main
      printf 'PARENT EDIT\n' > README.md && git add README.md
      git -c user.email=i@e -c user.name=I commit -q -m "parent README"
      git push -q fork feat/parent                 # parent branch exists on the fork (valid base)
      git checkout -q -b feat/child
      printf 'child\n' > c.txt && git add c.txt
      git -c user.email=i@e -c user.name=I commit -q -m "child c.txt" )
    parent_tip="$( cd "$SOURCE_DIR" && git rev-parse feat/parent )"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/child"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$parent_tip"
    fork_main_before=$( git -C "$FORK" rev-parse main )
    _advance_origin README.md UPSTREAM_EDIT        # origin/main now conflicts with the parent's README

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]                            # #26 skipped (stacked) → no conflict hard-stop
    grep -qE "gh pr create .* --base feat/parent( |$)" "$DEVAGENT_STUB_LOG"
    # Fork base NOT fast-forwarded (the #26 FF was skipped).
    [ "$( git -C "$FORK" rev-parse main )" = "$fork_main_before" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 x ship
}
