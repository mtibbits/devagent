#!/usr/bin/env bats
# Integration tests for mergetoall.sh #26 Defect-B pre-flight: refuse the squash
# when all_prs is behind upstream (would bundle the upstream delta into the
# issue commit). Real git + a local upstream remote; no gh (mergetoall is local).
load 'helpers/common'

setup() {
    devagent_test_setup
    UPSTREAM="$DEVAGENT_TMP/upstream.git"; git init -q --bare "$UPSTREAM"
    ( cd "$SOURCE_DIR"
      git remote add origin "$UPSTREAM"
      git push -q origin main                 # origin/main = C0
      git fetch -q origin
      git checkout -q -b dev/all-prs          # all_prs base = C0
      git checkout -q -b feat/1-x \
        && echo hi > a.txt && git add a.txt \
        && git -c user.email=t@e -c user.name=T commit -q -m "feat: x" )   # C2
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
}
teardown() { devagent_test_teardown; }

_advance_origin() {   # push one upstream commit so origin/main is ahead of all_prs
    ( cd "$SOURCE_DIR" && git checkout -q main \
      && printf 'up\n' > up.txt && git add up.txt \
      && git -c user.email=u@e -c user.name=U commit -q -m "upstream up.txt" \
      && git push -q origin main )
}

@test "mergetoall refuses to squash when all_prs is behind upstream" {
    _advance_origin
    all_prs_before=$( cd "$SOURCE_DIR" && git rev-parse dev/all-prs )

    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"behind"* ]]
    [[ "$output" == *"cherry-pick"* ]]
    # No squash landed; step 16 not marked done.
    [ "$( cd "$SOURCE_DIR" && git rev-parse dev/all-prs )" = "$all_prs_before" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 16 ' ' mergetoall
}

@test "mergetoall proceeds when all_prs is current with upstream" {
    # origin/main == all_prs (no drift) → behind 0 → squash as normal.
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]  # #71: success restores orig branch
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 16 x mergetoall
}
