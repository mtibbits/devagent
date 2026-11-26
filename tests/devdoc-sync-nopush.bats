#!/usr/bin/env bats
# tests/devdoc-sync-nopush.bats — #1149: devdoc_sync's no-push mode (step 21's
# sync before the WBS reconcile), over the #1148 fixture: a bare origin and two
# clones, A the other machine and B this one. Untagged (L258): these legs test the
# mode's logic, not platform behaviour, so they stay off the Git Bash job.
bats_require_minimum_version 1.5.0
load 'helpers/devdoc-sync'

setup() {
    R="$(mktemp -d -t devdoc-sync-nopush-XXXXXX)"
    export DEVAGENT_ROOT="$BATS_TEST_DIRNAME/.."
    unset DEVAGENT_DEVDOC_LOCK_TOKEN DEVAGENT_DEVDOC_LOCK_DEADLINE
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=2
    sync_fixture "$R"
}
teardown() { chmod -R u+w "$R" 2>/dev/null || true; rm -rf "$R"; }

# _calls <wrapper dir> <sub> — how many <sub> calls the wrapper logged.
_calls() { grep -cx -- "$2" "$1/calls" 2>/dev/null || true; }
_top() { (cd "$SYNC_B" && pwd -P); }
TAIL="This step uses this machine's copy; the next cleanup syncs again."

@test "#1149 no-push: diverged merges here once and pushes nothing" {
    sync_other a.txt 'from A' 'A: a.txt'
    T="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    sync_commit "$SYNC_B" b.txt 'from B' 'B: b.txt'
    H="$(git -C "$SYNC_B" rev-parse HEAD)"
    w="$BATS_TEST_TMPDIR/w"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$w" log)"
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_RC" = 0 ]
    [ "$SYNC_OUTCOME" = merged ]
    [ -z "$SYNC_REASON" ]
    [ "$(git -C "$SYNC_B" rev-parse HEAD^1)" = "$H" ]
    [ "$(git -C "$SYNC_B" rev-parse HEAD^2)" = "$T" ]
    [ "$(git -C "$SYNC_B" log -1 --format='%an <%ae>')" = 'devagent <devagent@local>' ]
    [ "$(git -C "$SYNC_B" log -1 --format='%cn <%ce>')" = 'devagent <devagent@local>' ]
    [ "$(git -C "$SYNC_B" log -1 --format=%s)" = 'devdoc: merge origin/main into main (Issue-7 wbs update)' ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$T" ]
    [ "$(_calls "$w" push)" = 0 ]
    [ "$(_calls "$w" fetch)" -ge 1 ]
}

@test "#1149 no-push: behind fast-forwards, ahead and a new remote stay local" {
    # (a) behind
    sync_other a.txt 'from A' 'A: a.txt'
    T="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_OUTCOME" = fast-forwarded ]
    [ "$(git -C "$SYNC_B" rev-parse HEAD)" = "$T" ]
    # (b) ahead
    sync_fixture "$R/b"
    O="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    sync_commit "$SYNC_B" b.txt b 'B: b'
    w="$BATS_TEST_TMPDIR/wb"
    DEVAGENT_GIT="$(sync_git_wrapper "$w" log)" sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_RC" = 0 ]
    [ "$SYNC_OUTCOME" = ahead ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$O" ]
    [ "$(_calls "$w" ls-remote)" -ge 1 ]
    [ "$(_calls "$w" push)" = 0 ]
    # (c) new remote
    sync_fixture "$R/c"
    git -c init.defaultBranch=main init -q --bare "$R/empty.git"
    git -C "$SYNC_B" remote set-url origin "$R/empty.git"
    sync_commit "$SYNC_B" b.txt b 'B: b'
    w="$BATS_TEST_TMPDIR/wc"
    DEVAGENT_GIT="$(sync_git_wrapper "$w" log)" sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_RC" = 0 ]
    [ "$SYNC_OUTCOME" = ahead ]
    run git -C "$R/empty.git" rev-parse -q --verify refs/heads/main
    [ "$status" -eq 1 ]
    [ "$(_calls "$w" ls-remote)" -ge 1 ]
    [ "$(_calls "$w" push)" = 0 ]
}

@test "#1149 merge subject: wbs update without an issue; cleanup's unchanged" {
    # (a) no issue, no-push
    sync_other a.txt 'from A' 'A: a.txt'
    sync_commit "$SYNC_B" b.txt 'from B' 'B: b.txt'
    sync_run "$SYNC_B_DOC" - 30 no-push
    [ "$SYNC_OUTCOME" = merged ]
    [ "$(git -C "$SYNC_B" log -1 --format=%s)" = 'devdoc: merge origin/main into main (wbs update)' ]
    # (b) push mode, as cleanup calls it
    sync_fixture "$R/b"
    sync_other a.txt 'from A' 'A: a.txt'
    sync_commit "$SYNC_B" b.txt 'from B' 'B: b.txt'
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_OUTCOME" = merged ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$(git -C "$SYNC_B" rev-parse HEAD)" ]
    [ "$(git -C "$SYNC_B" log -1 --format=%s)" = 'devdoc: merge origin/main into main (Issue-7 cleanup)' ]
}

@test "#1149 no-push: a busy lock is one attempt; push mode still waits" {
    devdoc_lock_stub_holder "$SYNC_B" Issue-9 >/dev/null
    sync_commit "$SYNC_B" b.txt b 'B: b'
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=5
    # (a) no-push: one attempt
    t0=$SECONDS
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    el=$((SECONDS - t0))
    [ "$SYNC_RC" = 1 ]
    [ "$SYNC_REASON" = lock-busy ]
    [ "$SYNC_OUTCOME" = skipped ]
    [ "$el" -lt 2 ]
    [ "$SYNC_LINE" = "devDoc sync skipped for $(_top) (main): the devDoc lock is busy. $TAIL" ]
    # (b) push mode keeps its bound
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=1
    t0=$SECONDS
    sync_run "$SYNC_B_DOC" Issue-7 30
    el=$((SECONDS - t0))
    [ "$SYNC_REASON" = lock-busy ]
    [ "$el" -ge 1 ]
}

@test "#1149 no-push: a conflict refuses with the step-21 line, nothing changed" {
    sync_other proj/WBS.md '# proj WBS from A' 'A: WBS'
    sync_commit "$SYNC_B" proj/WBS.md '# proj WBS from B' 'B: WBS'
    before="$(sync_snapshot "$SYNC_B")"
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    after="$(sync_snapshot "$SYNC_B")"
    [ "$SYNC_REASON" = conflict ]
    [ "$after" = "$before" ]
    [[ "$SYNC_LINE" == "devDoc sync refused for $(_top) (main): merging origin/main conflicts in "*"WBS.md. $TAIL" ]]
    [[ "$SYNC_LINE" != *"commits not on origin"* ]]
    # (b) a dirty path in the way keeps the core's remedy
    sync_fixture "$R/b"
    sync_other mod2 'origin mod2' 'A: mod2'
    printf 'B edit\n' >> "$SYNC_B/mod2"
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_REASON" = in-the-way ]
    [[ "$SYNC_LINE" == *"Commit the edits to mod2"* ]]
    [[ "$SYNC_LINE" == *". $TAIL" ]]
    [[ "$SYNC_LINE" != *"The next close retries"* ]]
    [[ "$SYNC_LINE" != *"commits not on origin"* ]]
}

@test "#1149 an unknown sync mode refuses before any network call" {
    sync_other a.txt 'from A' 'A: a.txt'
    w="$BATS_TEST_TMPDIR/w"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$w" log)"
    before="$(sync_snapshot "$SYNC_B")"
    sync_run "$SYNC_B_DOC" Issue-7 30 bogus
    after="$(sync_snapshot "$SYNC_B")"
    [ "$SYNC_RC" = 1 ]
    [ "$SYNC_REASON" = bad-mode ]
    [[ "$SYNC_LINE" == *"unknown sync mode 'bogus'"* ]]
    [ "$after" = "$before" ]
    n="$(grep -c '^start ' "$w/calls" 2>/dev/null || true)"
    [ "${n:-0}" = 0 ]
    # the positive control: the same wrapper logs this driver's network calls
    sync_run "$SYNC_B_DOC" Issue-7 30 no-push
    [ "$SYNC_OUTCOME" = fast-forwarded ]
    [ "$(grep -c '^start ' "$w/calls")" -ge 1 ]
    # (b) outside git: the mode is decided at entry, before the scope check
    mkdir -p "$R/plain"
    unset DEVAGENT_GIT
    sync_run "$R/plain" Issue-7 30 bogus
    [ "$SYNC_REASON" = bad-mode ]
    [ "$SYNC_OUTCOME" != off ]
}
