#!/usr/bin/env bats
# #571: the evidence pair must measure the checkout the work is in.
# run-suite.sh must refuse (no artifact) when invoked from another checkout of
# the SAME project — a linked git worktree or a separate clone — and stay
# silent from the configured tree, an unrelated project, or no checkout at all.
# WSL-only even per-file: the refusal asserts embed `git rev-parse
# --show-toplevel` output, which Git Bash spells C:/... against /tmp/...
# fixture vars (the active.sh:128-130 spelling asymmetry).
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    # An AD-HOC worktree: nothing recorded in state.worktree_path.
    WT="$DEVAGENT_TMP/wt"
    git worktree add -q -b wt-branch "$WT" HEAD
    ( cd "$WT" && echo delta > delta.txt && git add -A && git commit -q -m "worktree-only" )
    WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
    SRC_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    [ "$WT_HEAD" != "$SRC_HEAD" ]          # the fixture must actually diverge
    mkdir -p "$DEVAGENT_TMP/binstub"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

@test "#571 AC1: run-suite from an ad-hoc worktree REFUSES and writes no artifact" {
    # the guard must EXIST — a 127 would satisfy the rc assertion vacuously (#572)
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/paths.sh'; . '$DEVAGENT_ROOT/scripts/lib/io.sh'; . '$DEVAGENT_ROOT/scripts/lib/config.sh'; . '$DEVAGENT_ROOT/scripts/lib/state.sh'; . '$DEVAGENT_ROOT/scripts/lib/active.sh'; type active_guard_tree"
    [ "$status" -eq 0 ]
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"$WT"* ]] && [[ "$output" == *"$SOURCE_DIR"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]      # NO artifact: assert absence, not a stale-marker presence (#318)
}

@test "#571 AC1: the same run from the configured tree still writes its artifact" {
    # the guard's OTHER branch — a rewrite that fixes one direction must be shown
    # not to have turned fail-closed into fail-open (#558)
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571: DEVAGENT_TREE_GUARD_OVERRIDE=1 restores the old behavior for one call" {
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" DEVAGENT_TREE_GUARD_OVERRIDE=1 \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571 AC1: a separate CLONE of the same project REFUSES (widened clause)" {
    # The ~/devagent-wsl shape: not a linked worktree (own .git), same origin URL.
    git -C "$SOURCE_DIR" remote add origin https://example.invalid/acme/testproj.git
    CLONE="$DEVAGENT_TMP/clone"
    git clone -q "$SOURCE_DIR" "$CLONE"
    git -C "$CLONE" remote set-url origin https://example.invalid/acme/testproj.git
    # prove the fixture is the CLONE shape, not the worktree shape — otherwise this
    # test would pass on clause 1 and prove nothing about the widening
    A="$(cd "$CLONE" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    B="$(cd "$SOURCE_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    [ ! "$A" -ef "$B" ]
    ( cd "$CLONE" && git -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m clone-only )
    cd "$CLONE"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"separate clone"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]
}

@test "#571: a DIFFERENT project's checkout does NOT trip the guard (distinct origins)" {
    # Non-vacuous: both sides have a NON-EMPTY origin and they DIFFER, so the pass is
    # decided by inequality — not by the fail-open empty-URL leg, which the next test
    # covers separately.
    devagent_fixture_projB 1     # separate git init → different --git-common-dir
    git -C "$SOURCE_DIR" remote add origin https://example.invalid/acme/testproj.git
    git -C "$SRC_B"     remote add origin https://example.invalid/acme/projB.git
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"TREE MISMATCH"* ]]
}

@test "#571: a remote-less unrelated checkout FAILS OPEN — the guard's stated blind spot" {
    # Pins the DOCUMENTED behavior, so a later change that makes it fail closed
    # reddens here instead of silently breaking every fixture (register Issue-558:
    # the blind spot is part of the contract, so it gets a test like any other clause).
    devagent_fixture_projB 1     # no origin on either side
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "#571: cwd outside any git checkout does NOT trip the guard" {
    mkdir -p "$DEVAGENT_TMP/nowhere"
    cd "$DEVAGENT_TMP/nowhere"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}
