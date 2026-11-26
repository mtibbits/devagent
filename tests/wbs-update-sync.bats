#!/usr/bin/env bats
# tests/wbs-update-sync.bats — #1149: step 21 (`wbs.sh update`) brings devDoc's
# origin in before the WBS reconcile, through devdoc_sync's no-push mode, and
# cleanup's own reconcile does not. End to end over a real bare origin: the devDoc
# repository is $DEVDOC_REPO (devdoc_dir is its testproj/ subdirectory, this
# machine) and $SYNC_A is the other machine's clone. Untagged, like cleanup.bats.
bats_require_minimum_version 1.5.0
load 'helpers/common'
load 'helpers/devdoc-repo'
load 'helpers/devdoc-sync'
. "$BATS_TEST_DIRNAME/helpers/wbs-tracker.bash"
. "${BATS_TEST_DIRNAME}/lib/changelog-text.bash"

L1='  - [x] Working leaf {issue: Issue-1, est: 1w, status_src: tracker}'
L2X='  - [x] Next leaf {issue: Issue-2, est: 1w}'
L2O='  - [ ] Next leaf {issue: Issue-2, est: 1w}'

setup() {
    devagent_test_setup
    unset DEVAGENT_WBS_OFFLINE DEVAGENT_DEVDOC_LOCK_DEADLINE DEVAGENT_DEVDOC_SYNC_SECS DEVAGENT_GIT
    sync_closeout_ready "$DEVDOC_DIR/Issue-1"
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
}
# #735: cleanup starts the actuals rebuild detached; wait for it (bounded).
_wait_rebuild() {
    local pidf="$HOME/.claude/devagent/actuals-rebuild.pid" pid n=0
    [ -f "$pidf" ] || return 0
    pid="$(cat "$pidf")"
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
}
teardown() {
    local rc=0
    _wait_rebuild
    [ ! -e "$DEVAGENT_TMP/network.log" ] || { echo "a real backend CLI ran:" >&2; cat "$DEVAGENT_TMP/network.log" >&2; rc=1; }
    devagent_test_teardown
    return "$rc"
}

# _wbs_fixture [--no-git] — WBS.md, then (unless --no-git) the devDoc repository with
# its origin and clone A, then the tracker stub (Issue-1 done) and the CLI shims.
_wbs_fixture() {
    printf '%s\n' '# testproj WBS' '' '- [ ] Plan {est: 1w}' \
        '  - [~] Working leaf {issue: Issue-1, est: 1w}' \
        '  - [ ] Next leaf {issue: Issue-2, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    [ "${1:-}" = --no-git ] || sync_close_fixture
    export WBS_STUB_ROOT="$DEVAGENT_TMP"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/backends"
    export DEVAGENT_CODE_BACKEND_DIR="$DEVAGENT_TMP/code-backends"
    wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
    wbs_mr_install_stub "$DEVAGENT_CODE_BACKEND_DIR"
    printf '1\tdone\n' > "$DEVAGENT_TMP/state-list.github"
    wbs_tracker_install_shims "$DEVAGENT_TMP/shims" "$DEVAGENT_TMP/network.log"
    export PATH="$DEVAGENT_TMP/shims:$PATH"
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=30
}
# _a_flip — the other machine marks Issue-2 done and pushes; sets a (its tip).
_a_flip() {
    sed -i 's/^  - \[ \] Next leaf/  - [x] Next leaf/' "$SYNC_A/testproj/WBS.md"
    git -C "$SYNC_A" commit -q -am 'A: Issue-2 done'
    git -C "$SYNC_A" push -q origin main 2>/dev/null
    a="$(git -C "$SYNC_A" rev-parse HEAD)"
}
_upd() { "$DEVAGENT_ROOT/scripts/wbs.sh" update "$TEST_PROJECT" "$@"; }
_head() { git -C "$DEVDOC_REPO" rev-parse HEAD; }
_has() { grep -qxF -- "$1" "$DEVDOC_DIR/WBS.md"; }
_cleanup() { run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1; }
_nsync() { grep -c 'devDoc sync' <<< "$1" || true; }

@test "#1149 behind at step 21: lands on origin's WBS.md; cleanup pushes clean" {
    _wbs_fixture
    _a_flip
    run _upd
    [ "$status" -eq 0 ]
    [ "$(_nsync "$output")" = 0 ]
    [ "$(_head)" = "$a" ]
    _has "$L1"
    _has "$L2X"
    _cleanup
    [ "$status" -eq 0 ]
    [ "$(_nsync "$output")" = 0 ]
    git -C "$SYNC_ORIGIN" log --format=%s refs/heads/main | grep -qx 'devdoc: Issue-1 cleanup'
    [ "$(git -C "$SYNC_ORIGIN" rev-list --merges --count refs/heads/main)" = 0 ]
}

@test "#1149 diverged at step 21: one devagent merge, origin untouched; cleanup pushes both" {
    _wbs_fixture
    sync_commit "$DEVDOC_REPO" statusreport.md report 'statusreport: 2026-11-26'
    sr="$(_head)"
    _a_flip
    run _upd
    [ "$status" -eq 0 ]
    [ "$(git -C "$DEVDOC_REPO" rev-parse HEAD^1)" = "$sr" ]
    [ "$(git -C "$DEVDOC_REPO" rev-parse HEAD^2)" = "$a" ]
    [ "$(git -C "$DEVDOC_REPO" log -1 --format='%an <%ae>|%cn <%ce>|%s')" = 'devagent <devagent@local>|devagent <devagent@local>|devdoc: merge origin/main into main (Issue-1 wbs update)' ]
    m="$(_head)"
    _has "$L1"
    _has "$L2X"
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$a" ]
    _cleanup
    [ "$status" -eq 0 ]
    [ "$(_nsync "$output")" = 0 ]
    o="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    git -C "$SYNC_ORIGIN" merge-base --is-ancestor "$sr" "$o"
    git -C "$SYNC_ORIGIN" merge-base --is-ancestor "$m" "$o"
    [ "$(git -C "$SYNC_ORIGIN" rev-list --merges --count "$o")" = 1 ]
}

@test "#1149 control: without the sync the same close conflicts at cleanup" {
    _wbs_fixture
    _a_flip
    h="$(_head)"
    run "$DEVAGENT_ROOT/scripts/wbs-update.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ "$(_head)" = "$h" ]
    _has "$L1"
    _has "$L2O"
    _cleanup
    [ "$status" -eq 0 ]
    [ "$(grep -c 'WARNING: devDoc sync refused' <<< "$output")" = 1 ]
    line="$(grep 'WARNING: devDoc sync refused' <<< "$output")"
    [[ "$line" == *"conflicts in"* ]]
    [[ "$line" == *WBS.md* ]]
}

@test "#1149 edited WBS.md in the way: one info line, this copy reconciled, edit kept" {
    _wbs_fixture
    printf '%s\n' '- [ ] Hand-added {est: 1d}' >> "$DEVDOC_DIR/WBS.md"
    _a_flip
    h="$(_head)"
    run _upd
    [ "$status" -eq 0 ]
    [ "$(_nsync "$output")" = 1 ]
    line="$(grep 'devDoc sync' <<< "$output")"
    [[ "$line" == "wbs-update.sh: wbs update: devDoc sync refused for "* ]]
    [[ "$line" == *"in the way"* ]]
    [[ "$line" == *testproj/WBS.md* ]]
    [[ "$line" == *"This step uses this machine's copy; the next cleanup syncs again." ]]
    [[ "$output" != *WARNING:* ]]
    [ "$(_head)" = "$h" ]
    _has "$L1"
    _has "$L2O"
    _has '- [ ] Hand-added {est: 1d}'
}

@test "#1149 busy lock: the sync skips at once; the reconcile's write waits and lands" {
    _wbs_fixture
    _a_flip
    h="$(_head)"
    lp="$(devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-9)"
    bd="$DEVAGENT_TMP/backends-e5"
    mkdir -p "$bd"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'if [ "${1:-}" = state-list ]; then'
        printf '  ( sleep 2; rm -f %q/holder; rmdir %q ) >/dev/null 2>&1 3>&- &\n' "$lp" "$lp"
        printf '%s\n' "  printf '1\\tdone\\n'" '  exit 0' 'fi' 'exit 78'
    } > "$bd/github.sh"
    chmod +x "$bd/github.sh"
    DEVAGENT_ISSUE_BACKEND_DIR="$bd" run _upd
    [ "$status" -eq 0 ]
    [ "$(grep -c 'devDoc sync skipped' <<< "$output")" = 1 ]
    [ "$(_nsync "$output")" = 1 ]
    [[ "$(grep 'devDoc sync' <<< "$output")" == *"the devDoc lock is busy"* ]]
    [[ "$output" == *"waiting for devdoc lock"* ]]
    _has "$L1"
    [ "$(_head)" = "$h" ]
    [ ! -e "$lp" ]
}

@test "#1149 unreachable origin: one info line; exit and result as without the sync" {
    _wbs_fixture
    _a_flip
    rm -rf "$SYNC_ORIGIN"
    cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/wbs.save"
    run _upd
    s1="$status"; out1="$output"; cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/w1"
    cp "$DEVAGENT_TMP/wbs.save" "$DEVDOC_DIR/WBS.md"
    run "$DEVAGENT_ROOT/scripts/wbs-update.sh" "$TEST_PROJECT"
    s2="$status"; out2="$output"; cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/w2"
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    [ "$(grep -c 'devDoc sync refused' <<< "$out1")" = 1 ]
    [ "$(_nsync "$out1")" = 1 ]
    line="$(grep 'devDoc sync' <<< "$out1")"
    [[ "$line" == *"the fetch failed"* ]]
    [[ "$line" == *"the next cleanup syncs again"* ]]
    [ "$(grep -v 'devDoc sync' <<< "$out1")" = "$out2" ]
    cmp "$DEVAGENT_TMP/w1" "$DEVAGENT_TMP/w2"
}

# _off_leg <label> [args…] — wbs.sh update and the flagless wbs-update.sh, each from the
# same WBS.md and under its own logging wrapper: same output, same bytes, no sync call.
_off_leg() {
    local label="$1" h="" o1 w1="$DEVAGENT_TMP/off-$1-1" w2="$DEVAGENT_TMP/off-$1-2"
    shift
    [ -z "${DEVDOC_REPO:-}" ] || h="$(_head)"
    cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/wbs.save"
    DEVAGENT_GIT="$(sync_git_wrapper "$w1" log)" run _upd "$@"
    [ "$status" -eq 0 ] || { echo "$label: wbs.sh update exited $status: $output" >&2; return 1; }
    o1="$output"; cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/off-$label.w1"
    cp "$DEVAGENT_TMP/wbs.save" "$DEVDOC_DIR/WBS.md"
    DEVAGENT_GIT="$(sync_git_wrapper "$w2" log)" run "$DEVAGENT_ROOT/scripts/wbs-update.sh" "$TEST_PROJECT" "$@"
    [ "$status" -eq 0 ] || { echo "$label: wbs-update.sh exited $status" >&2; return 1; }
    [ "$o1" = "$output" ] || { echo "$label: output differs:" >&2; diff <(echo "$o1") <(echo "$output") >&2; return 1; }
    cmp "$DEVAGENT_TMP/off-$label.w1" "$DEVDOC_DIR/WBS.md" || { echo "$label: WBS.md differs" >&2; return 1; }
    [ -z "$h" ] || [ "$(_head)" = "$h" ] || { echo "$label: HEAD moved" >&2; return 1; }
    [ -s "$w1/calls" ] || { echo "$label: the wrapper logged nothing (run 1)" >&2; return 1; }
    [ -s "$w2/calls" ] || { echo "$label: the wrapper logged nothing (run 2)" >&2; return 1; }
    [ "$(grep -cxE 'ls-remote|fetch|push|merge|merge-tree|commit-tree' "$w1/calls" || true)" = 0 ] \
        || { echo "$label: a sync call ran:" >&2; cat "$w1/calls" >&2; return 1; }
}

@test "#1149 off: no git network call and unchanged output in each off state" {
    _wbs_fixture; _a_flip                                            # (a) no origin
    git -C "$DEVDOC_REPO" remote remove origin
    _off_leg no-origin
    teardown; setup; _wbs_fixture; _a_flip                           # (b) commit_devdoc=false
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    _off_leg no-commit-devdoc
    teardown; setup; unset DEVDOC_REPO; _wbs_fixture --no-git        # (c) outside git
    _off_leg outside-git
    teardown; setup; _wbs_fixture; _a_flip                           # (d) --offline
    _off_leg offline-flag --offline
    teardown; setup; _wbs_fixture; _a_flip                           # (e) DEVAGENT_WBS_OFFLINE=1
    export DEVAGENT_WBS_OFFLINE=1
    _off_leg offline-env
    unset DEVAGENT_WBS_OFFLINE
}

# _rows_before <log> <n> — the rows before row <n> whose subcommand is a sync call.
_sync_rows() { awk -F'\t' -v c="$2" 'NR < c && ($1 == "ls-remote" || $1 == "fetch" || $1 == "merge" || $1 == "merge-tree" || $1 == "commit-tree")' "$1"; }

@test "#1149 cleanup's reconcile does not sync" {
    _wbs_fixture
    sync_other other.md 'from A' 'A: other.md'
    log="$DEVAGENT_TMP/git.log"
    DEVAGENT_GIT="$(devdoc_git_logging_wrapper "$log")" _cleanup
    [ "$status" -eq 0 ]
    c="$(awk -F'\t' '$1 == "commit" && $10 ~ /devdoc: Issue-1 cleanup/ { print NR; exit }' "$log")"
    [ -n "$c" ]
    [ -z "$(_sync_rows "$log" "$c")" ]
    awk -F'\t' -v c="$c" 'NR > c && $1 == "fetch" { f = 1 } END { exit !f }' "$log"
    # (b) cleanup's exact argv, alone
    teardown; setup; _wbs_fixture
    sync_other other.md 'from A' 'A: other.md'
    h="$(_head)"
    log="$DEVAGENT_TMP/git.log"
    DEVAGENT_GIT="$(devdoc_git_logging_wrapper "$log")" run "$DEVAGENT_ROOT/scripts/wbs-update.sh" --if-exists --skip-state-slot "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -s "$log" ]
    [ -z "$(_sync_rows "$log" 999999)" ]
    [ "$(_head)" = "$h" ]
}

@test "#1149 lock use: network unheld; merge and move held by wbs-update.sh" {
    _wbs_fixture
    sync_commit "$DEVDOC_REPO" statusreport.md report 'statusreport: 2026-11-26'
    _a_flip
    log="$DEVAGENT_TMP/git.log"
    DEVAGENT_GIT="$(devdoc_git_logging_wrapper "$log")" run _upd
    [ "$status" -eq 0 ]
    for sub in ls-remote fetch; do
        [ "$(awk -F'\t' -v s="$sub" '$1 == s' "$log" | wc -l)" -ge 1 ]
        [ -z "$(awk -F'\t' -v s="$sub" '$1 == s && $8 != "-"' "$log")" ]
    done
    for sub in merge-tree commit-tree merge; do
        [ "$(awk -F'\t' -v s="$sub" '$1 == s' "$log" | wc -l)" -ge 1 ]
        [ -z "$(awk -F'\t' -v s="$sub" '$1 == s && $8 != "wbs-update.sh"' "$log")" ]
    done
    [ -z "$(awk -F'\t' '$1 == "push"' "$log")" ]
}

@test "#1149 wbs update: sync bounded by DEVAGENT_DEVDOC_SYNC_SECS" {
    _wbs_fixture
    _a_flip
    h="$(_head)"
    DEVAGENT_DEVDOC_SYNC_SECS=1 DEVAGENT_GIT="$(sync_git_wrapper "$DEVAGENT_TMP/w" slow:2)" run _upd
    [ "$status" -eq 0 ]
    [ "$(_nsync "$output")" = 1 ]
    [[ "$(grep 'devDoc sync' <<< "$output")" == *"time budget ran out"* ]]
    [ "$(_head)" = "$h" ]
    _has "$L1"
}
