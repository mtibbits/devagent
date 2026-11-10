#!/usr/bin/env bats
# #749: two sessions closing issues of two projects that share one devDoc
# repository serialise on the repository lock, and each cleanup commits only
# its own paths. Deterministic: A is paused INSIDE its devdoc commit by the
# gate wrapper, B is started only then, and A is released only once B is
# observably waiting (or has exited) — no timed race window.
load 'helpers/common'
load 'helpers/devdoc-repo'

setup() {
    devagent_test_setup
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    two_project_devdoc_fixture
}
teardown() { devagent_test_teardown; }

@test "#749: B waits on A's lock and each commits only its own paths" {
    a="$DEVAGENT_TMP/gateA"; b="$DEVAGENT_TMP/gateB"
    wa="$(devdoc_git_gate_wrapper "$a")"; wb="$(devdoc_git_gate_wrapper "$b")"
    : > "$a/pause"
    seed="$(git -C "$DEVDOC_REPO" rev-parse HEAD)"
    DEVAGENT_GIT="$wa" "$DEVAGENT_ROOT/scripts/cleanup.sh" projA Issue-1 \
        > "$DEVAGENT_TMP/A.out" 2> "$DEVAGENT_TMP/A.err" 3>&- &
    pa=$!
    n=0; until [ -e "$a/in-commit" ]; do
        n=$((n + 1)); [ "$n" -lt 600 ] || { kill "$pa"; echo "A never reached its commit"; cat "$DEVAGENT_TMP/A.err"; false; }
        sleep 0.1
    done
    DEVAGENT_DEVDOC_LOCK_TIMEOUT=60 DEVAGENT_GIT="$wb" "$DEVAGENT_ROOT/scripts/cleanup.sh" projB Issue-1 \
        > "$DEVAGENT_TMP/B.out" 2> "$DEVAGENT_TMP/B.err" 3>&- &
    pb=$!
    n=0; until grep -q 'waiting for devdoc lock' "$DEVAGENT_TMP/B.err" 2>/dev/null || ! kill -0 "$pb" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -lt 600 ] || break
        sleep 0.1
    done
    : > "$a/gate"
    rc_a=0; wait "$pa" || rc_a=$?
    rc_b=0; wait "$pb" || rc_b=$?
    cat "$DEVAGENT_TMP/A.err" "$DEVAGENT_TMP/B.err"
    [ "$rc_a" -eq 0 ]
    [ "$rc_b" -eq 0 ]
    ! grep -q 'index.lock' "$DEVAGENT_TMP/A.err" "$DEVAGENT_TMP/B.err" || false
    grep -q 'waiting for devdoc lock' "$DEVAGENT_TMP/B.err"         # B waited
    [ "$(git -C "$DEVDOC_REPO" rev-parse HEAD~2)" = "$seed" ]
    run git -C "$DEVDOC_REPO" show --name-only --format= HEAD~1
    [ -z "$(printf '%s\n' "$output" | grep -vE '^projA/(Issue-1/.*|WBS\.md)$')" ]
    [[ "$output" == *"projA/Issue-1/checklist.md"* ]]
    [[ "$output" == *"projA/WBS.md"* ]]
    run git -C "$DEVDOC_REPO" show --name-only --format= HEAD
    [ -z "$(printf '%s\n' "$output" | grep -vE '^projB/(Issue-1/.*|WBS\.md)$')" ]
    [[ "$output" == *"projB/Issue-1/checklist.md"* ]]
    [[ "$output" == *"projB/WBS.md"* ]]
    [ ! -e "$DEVAGENT_TMP/network.log" ]
}
