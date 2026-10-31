#!/usr/bin/env bats
# #885 A0.5: scripts/rebaseline.sh re-keys baseline_sha to the merge base of
# default_baseline and HEAD after a merge-forward, and refuses every shape where
# that base is ambiguous (criss-cross), backwards (a stale local base ref) or
# measured on the wrong branch. Real throwaway git repos: a bare `origin`, an
# upstream working clone that advances it, and the test project's SOURCE_DIR.
load 'helpers/common'

setup() {
    devagent_test_setup
    export ORIGIN="$DEVAGENT_TMP/origin.git" UPWC="$DEVAGENT_TMP/upstream-wc"
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export CL="$DEVDOC_DIR/Issue-1/checklist.md"
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    ( cd "$SOURCE_DIR" \
      && git remote add origin "$ORIGIN" \
      && git push -q origin main \
      && git fetch -q origin \
      && git checkout -q -b feat/1-x \
      && echo f1 > f1.txt && git add f1.txt && git commit -q -m f1 )
    git clone -q -b main "$ORIGIN" "$UPWC"
    git -C "$UPWC" config user.email up@example.com
    git -C "$UPWC" config user.name Upstream
    C0="$(git -C "$SOURCE_DIR" rev-parse main)"
    devagent_state_set "$STATE" branch "feat/1-x"
    devagent_state_set "$STATE" baseline_sha "$C0"
}
teardown() { devagent_test_teardown; }

# _upstream_commit <name>: advance origin's main by one commit; print its SHA.
_upstream_commit() {
    ( cd "$UPWC" && echo "$1" > "$1.txt" && git add "$1.txt" && git commit -q -m "$1" \
      && git push -q origin main && git rev-parse HEAD )
}

# _merge_forward: merge the current origin/main into the issue branch.
_merge_forward() {
    ( cd "$SOURCE_DIR" && git fetch -q origin && git merge -q --no-edit origin/main )
}

# _baseline: the issue's baseline_sha as the step scripts read it.
_baseline() {
    bash -c '
        set -euo pipefail
        DEVAGENT_ROOT="$1"
        . "$DEVAGENT_ROOT/scripts/lib/paths.sh"
        . "$DEVAGENT_ROOT/scripts/lib/io.sh"
        . "$DEVAGENT_ROOT/scripts/lib/config.sh"
        . "$DEVAGENT_ROOT/scripts/lib/state.sh"
        . "$DEVAGENT_ROOT/scripts/lib/active.sh"
        state_ctx_get "$2" baseline_sha Issue-1
    ' _ "$DEVAGENT_ROOT" "$TEST_PROJECT"
}

_snapshot() { cp "$STATE" "$DEVAGENT_TMP/state.before"; cp "$CL" "$DEVAGENT_TMP/cl.before"; }
_untouched() { cmp -s "$STATE" "$DEVAGENT_TMP/state.before" && cmp -s "$CL" "$DEVAGENT_TMP/cl.before"; }

@test "#885 rebaseline re-keys to the merge base after a merge-forward" {
    local c1 c2
    c1="$(_upstream_commit u1)"
    _merge_forward
    c2="$(_upstream_commit u2)"     # origin moves on: the fetch sees it, the merge base stays c1
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebaseline: baseline_sha ${C0:0:7} → ${c1:0:7}"* ]]
    [ "$(_baseline)" = "$c1" ]
    grep -qE "^- [0-9-]+ [0-9:]+  rebaseline: baseline_sha ${C0:0:7} → ${c1:0:7}$" "$CL"
    [ "$(git -C "$SOURCE_DIR" rev-parse origin/main)" = "$c2" ]    # the fetch ran
}

@test "#885 rebaseline: unchanged is a no-op" {
    _snapshot
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT" Issue-1
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebaseline: baseline_sha unchanged (${C0:0:7})"* ]]
    _untouched
}

@test "#885 rebaseline: criss-cross history with two merge bases refuses" {
    local a b
    # c0 ── A (main) ──── M1 = merge(A, B)   (main, pushed to origin)
    #   └── B (feat) ──── M2 = merge(B, A)   (feat/1-x = HEAD)
    # merge-base --all origin/main HEAD = {A, B}: neither contains the other.
    b="$(git -C "$SOURCE_DIR" rev-parse feat/1-x)"
    ( cd "$SOURCE_DIR" \
      && git checkout -q main && echo a > a.txt && git add a.txt && git commit -q -m A )
    a="$(git -C "$SOURCE_DIR" rev-parse main)"
    ( cd "$SOURCE_DIR" \
      && git merge -q --no-edit "$b" && git push -q origin main \
      && git checkout -q feat/1-x && git merge -q --no-edit "$a" )
    [ "$(git -C "$SOURCE_DIR" merge-base --all main feat/1-x | wc -l)" -eq 2 ]
    _snapshot
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"rebaseline: 2 merge bases between origin/main and HEAD; refusing to pick one — set baseline_sha by hand"* ]]
    _untouched
}

@test "#885 rebaseline: stale local base ref older than the fork point is refused, state untouched" {
    local c1
    c1="$(_upstream_commit u1)"
    _merge_forward
    devagent_state_set "$STATE" baseline_sha "$c1"          # the branch's recorded base is c1
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$C0"   # local base ref left behind
    git -C "$SOURCE_DIR" remote set-url origin "$DEVAGENT_TMP/gone.git"  # and no fetch can fix it
    _snapshot
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"rebaseline: new base ${C0:0:7} does not contain the recorded baseline ${c1:0:7}; refusing to move it backwards"* ]]
    _untouched
}

@test "#885 rebaseline refuses off-branch" {
    git -C "$SOURCE_DIR" checkout -q main
    _snapshot
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"rebaseline: HEAD is on main, not the issue branch feat/1-x"* ]]
    _untouched
}

@test "#885 rebaseline: fetch failure warns and still re-keys" {
    local c1
    c1="$(_upstream_commit u1)"
    _merge_forward
    git -C "$SOURCE_DIR" remote set-url origin "$DEVAGENT_TMP/gone.git"
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebaseline: could not fetch 'origin' (git fetch exited "*"); using the last-known origin/main"* ]]
    [[ "$output" == *"rebaseline: baseline_sha ${C0:0:7} → ${c1:0:7}"* ]]
    [ "$(_baseline)" = "$c1" ]
}
