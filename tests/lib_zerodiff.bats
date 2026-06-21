#!/usr/bin/env bats
# #241 — unit coverage for the shared zero-diff-guard helper. The guard's
# fail-safe direction (a git error must NEVER authorize a silent skip; #25/#68)
# is a correctness invariant, so it is tested directly here rather than only
# through the three consumer scripts.
load 'helpers/common'

setup() {
    devagent_test_setup
    . "$DEVAGENT_ROOT/scripts/lib/zerodiff.sh"
    # A real throwaway git repo: baseline commit + a feature branch.
    REPO="$DEVAGENT_TMP/zd-repo"
    git init -q "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name Test
    echo base > "$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -q -m base
    BASELINE="$(git -C "$REPO" rev-parse HEAD)"
}
teardown() { devagent_test_teardown; }

@test "zero_diff_classify: commits ahead of baseline → 'commits'" {
    git -C "$REPO" checkout -q -b feat/x
    echo more > "$REPO/b.txt"
    git -C "$REPO" add b.txt
    git -C "$REPO" commit -q -m work
    run zero_diff_classify git "$REPO" feat/x "$BASELINE"
    [ "$status" -eq 0 ]
    [ "$output" = "commits" ]
}

@test "zero_diff_classify: no commits ahead (ref == baseline) → 'empty'" {
    # HEAD is the baseline commit itself → zero commits ahead.
    run zero_diff_classify git "$REPO" HEAD "$BASELINE"
    [ "$status" -eq 0 ]
    [ "$output" = "empty" ]
}

@test "zero_diff_classify: empty baseline arg → 'indeterminate' (never skip)" {
    run zero_diff_classify git "$REPO" HEAD ""
    [ "$status" -eq 0 ]
    [ "$output" = "indeterminate" ]
}

@test "zero_diff_classify: rev-list failure (bad baseline ref) → 'indeterminate' (fail-safe)" {
    # A baseline that does not resolve makes rev-list exit non-zero — this MUST
    # become 'indeterminate', not 'empty', so no caller silently skips (#25/#68).
    run zero_diff_classify git "$REPO" HEAD "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    [ "$status" -eq 0 ]
    [ "$output" = "indeterminate" ]
}

@test "zero_diff_classify: not-a-git-repo → 'indeterminate' (fail-safe)" {
    mkdir -p "$DEVAGENT_TMP/not-a-repo"
    run zero_diff_classify git "$DEVAGENT_TMP/not-a-repo" HEAD "$BASELINE"
    [ "$status" -eq 0 ]
    [ "$output" = "indeterminate" ]
}
