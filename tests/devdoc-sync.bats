#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/devdoc-sync.bats — #1148: cleanup's devDoc sync with origin
# (devdoc_sync in scripts/lib/devdoc-repo.sh), over a real bare origin and two
# clones: A stands in for the other machine, B for this one. Each helper test
# passes B's subdirectory proj/ as devdoc_dir, as a project's devdoc_dir is.
bats_require_minimum_version 1.5.0
load 'helpers/devdoc-sync'

setup() {
    R="$(mktemp -d -t devdoc-sync-XXXXXX)"
    export DEVAGENT_ROOT="$BATS_TEST_DIRNAME/.."
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=2
    sync_fixture "$R"
}
teardown() { chmod -R u+w "$R" 2>/dev/null || true; rm -rf "$R"; }

# _fns <name>… — every name is a defined function (L45: a 127 never passes a test).
_fns() {
    local f bad=()
    for f in "$@"; do [ "$(type -t "$f")" = function ] || bad+=("$f"); done
    [ "${#bad[@]}" -eq 0 ] || { printf 'not a function: %s\n' "${bad[@]}" >&2; return 1; }
}

@test "#1148 sync helpers exist (task 1: the fixture)" {
    _fns sync_fixture sync_commit sync_other sync_snapshot sync_run sync_git_wrapper
    [ "$(git -C "$SYNC_B" rev-parse HEAD)" = "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" ]
    [ -f "$SYNC_B_DOC/WBS.md" ] && [ -f "$SYNC_B/hd/keep1" ] && [ -f "$SYNC_B/.gitignore" ]
    [ "$(git -C "$SYNC_B" config user.email)" = t@example.com ]
}

_libs() { . "$DEVAGENT_ROOT/scripts/lib/io.sh"; . "$DEVAGENT_ROOT/scripts/lib/devdoc-repo.sh"; }

@test "#1148 sync helpers exist (task 2: the budget primitives, via devdoc-repo.sh)" {
    _libs
    _fns bounded_now_us bounded_secs_left _upstream_fetch_branch merge_forward_merge
}

@test "#1148 sync helpers exist (task 3: the sync)" {
    _libs
    _fns devdoc_sync devdoc_sync_repo devdoc_unpushed_text _devdoc_sync_state _devdoc_sync_track _devdoc_sync_hold
}

# _st <clone> <path> — the two porcelain status letters of <path>.
_st() { git -C "$1" status --porcelain -- "$2" | cut -c1-2; }
# _calls <wrapper dir> <sub> — how many <sub> calls the wrapper logged.
_calls() { grep -cx -- "$2" "$1/calls" || true; }

@test "#1148 diverged: one devagent merge on origin and HEAD; local edits survive" {
    sync_other a.txt 'from A' 'A: a.txt'
    T="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    sync_commit "$SYNC_B" b.txt 'from B' 'B: b.txt'
    H="$(git -C "$SYNC_B" rev-parse HEAD)"
    printf 'edited\n' >> "$SYNC_B/ed"; cp "$SYNC_B/ed" "$BATS_TEST_TMPDIR/ed"
    printf 'staged\n' >> "$SYNC_B/st"; git -C "$SYNC_B" add st
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 0 ]; [ "$SYNC_OUTCOME" = merged ]; [ -z "$SYNC_LINE" ]
    M="$(git -C "$SYNC_B" rev-parse HEAD)"
    [ "$M" = "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" ]
    [ "$(git -C "$SYNC_B" log -1 --format=%P "$M")" = "$H $T" ]
    [ "$(git -C "$SYNC_B" log -1 --format='%an <%ae>|%cn <%ce>' "$M")" = 'devagent <devagent@local>|devagent <devagent@local>' ]
    [[ "$(git -C "$SYNC_B" log -1 --format='%s' "$M")" == *main*Issue-7* ]]
    ! git -C "$SYNC_B" log -1 --format='%ae %ce' "$M" | grep -q t@example.com || false
    [ "$(cat "$SYNC_B/a.txt")" = 'from A' ]
    cmp "$SYNC_B/ed" "$BATS_TEST_TMPDIR/ed"
    [ "$(_st "$SYNC_B" ed)" = ' M' ]
    [ "$(_st "$SYNC_B" st)" = 'M ' ]
}

@test "#1148 ahead only, with a local merge and a tag named main" {
    git -C "$SYNC_B" checkout -q -b side
    sync_commit "$SYNC_B" side.txt side 'B: side'
    git -C "$SYNC_B" checkout -q main
    sync_commit "$SYNC_B" b.txt b 'B: b'
    git -C "$SYNC_B" merge -q --no-ff -m 'local merge' side
    git -C "$SYNC_B" tag main
    H="$(git -C "$SYNC_B" rev-parse refs/heads/main)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 0 ]; [ "$SYNC_OUTCOME" = pushed ]
    [ "$(git -C "$SYNC_B" rev-parse refs/heads/main)" = "$H" ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$H" ]
    ! git -C "$SYNC_ORIGIN" rev-parse -q --verify refs/heads/heads/main || false
}

@test "#1148 behind only: fast-forward, no push" {
    sync_other a.txt 'from A' 'A: a.txt'
    T="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" log)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 0 ]; [ "$SYNC_OUTCOME" = fast-forwarded ]
    [ "$(git -C "$SYNC_B" rev-parse HEAD)" = "$T" ]
    [ "$(cat "$SYNC_B/a.txt")" = 'from A' ]
    [ "$(_calls "$BATS_TEST_TMPDIR/w" merge)" -ge 1 ]
    [ "$(_calls "$BATS_TEST_TMPDIR/w" push)" = 0 ]
}

@test "#1148 new remote: empty origin receives HEAD" {
    git -c init.defaultBranch=main init -q --bare "$R/empty.git"
    git -C "$SYNC_B" remote set-url origin "$R/empty.git"
    sync_commit "$SYNC_B" b.txt b 'B: b'
    H="$(git -C "$SYNC_B" rev-parse HEAD)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 0 ]; [ "$SYNC_OUTCOME" = pushed ]
    [ "$(git -C "$R/empty.git" rev-parse refs/heads/main)" = "$H" ]
    [ "$(git -C "$SYNC_B" rev-parse HEAD)" = "$H" ]
    [ "$(git -C "$SYNC_B" rev-parse refs/remotes/origin/main)" = "$H" ]
}

@test "#1148 same: no push; a lagging tracking ref catches up" {
    seed="$(git -C "$SYNC_B" rev-parse HEAD)"
    sync_other a.txt 'from A' 'A: a.txt'
    git -C "$SYNC_B" pull -q --ff-only origin main
    git -C "$SYNC_B" update-ref refs/remotes/origin/main "$seed"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" log)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 0 ]; [ "$SYNC_OUTCOME" = same ]
    [ "$(git -C "$SYNC_B" rev-parse refs/remotes/origin/main)" = "$(git -C "$SYNC_B" rev-parse HEAD)" ]
    [ "$(_calls "$BATS_TEST_TMPDIR/w" push)" = 0 ]
}

@test "#1148 narrowed fetch refspec: tracking ref is the pushed SHA" {
    git -C "$SYNC_B" config remote.origin.fetch '+refs/heads/other:refs/remotes/origin/other'
    sync_commit "$SYNC_B" b.txt b 'B: b'
    H="$(git -C "$SYNC_B" rev-parse HEAD)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_OUTCOME" = pushed ]
    [ "$(git -C "$SYNC_B" rev-parse refs/remotes/origin/main)" = "$H" ]
    _libs
    rc=0; devdoc_unpushed_text "$SYNC_B" main || rc=$?
    [ "$rc" -eq 1 ]
}

@test "#1148 sync helpers exist (task 4: refusals)" {
    _libs
    _fns devdoc_mid_operation
}

# _refuses <token> [--no-origin] — the sync warns with <token> and changes nothing.
_refuses() {
    local before after
    before="$(sync_snapshot "$SYNC_B" ${2:-})"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_RC" = 1 ] || { echo "rc=$SYNC_RC outcome=$SYNC_OUTCOME line=$SYNC_LINE" >&2; return 1; }
    [ "$SYNC_REASON" = "$1" ] || { echo "reason=$SYNC_REASON (want $1): $SYNC_LINE" >&2; return 1; }
    after="$(sync_snapshot "$SYNC_B" ${2:-})"
    [ "$after" = "$before" ] || { echo "snapshot changed:" >&2; diff <(echo "$before") <(echo "$after") >&2; return 1; }
}
# _leg <name> — a fresh fixture under $R/<name> with origin one commit ahead of B.
_leg() { sync_fixture "$R/$1"; sync_other a.txt 'from A' 'A: a.txt'; }
_lockdir() { printf '%s/devagent-devdoc.lock\n' "$(cd "$SYNC_B" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"; }
_stub_holder() {
    mkdir "$1"
    printf '%s\n' token=4242.1700000000.7 pid=4242 host=otherhost issue=Issue-9 \
        start=2026-11-01T10:00:00Z cmd=cleanup.sh > "$1/holder"
}

@test "#1148 conflict on WBS.md: named, nothing changed" {
    sync_other proj/WBS.md '# proj WBS from A' 'A: WBS'
    sync_commit "$SYNC_B" proj/WBS.md '# proj WBS from B' 'B: WBS'
    _refuses conflict
    [[ "$SYNC_LINE" == *"conflicts in proj/WBS.md."* ]]
    [[ "$SYNC_LINE" == *"by hand"* ]]
}

@test "#1148 in the way: edited, deleted, untracked and ignored files named and intact" {
    # leg a: git's own pre-check
    git -C "$SYNC_A" rm -q mod2 >/dev/null
    printf 'origin mod2\n' > "$SYNC_A/mod2"; printf 'origin new1\n' > "$SYNC_A/new1"; printf 'origin x\n' > "$SYNC_A/x.ign"
    git -C "$SYNC_A" add mod2 new1; git -C "$SYNC_A" add -f x.ign
    git -C "$SYNC_A" commit -q -m 'A: mod2 new1 x.ign'; git -C "$SYNC_A" push -q origin main 2>/dev/null
    printf 'B edit\n' >> "$SYNC_B/mod2"; printf 'B new1\n' > "$SYNC_B/new1"; printf 'B x\n' > "$SYNC_B/x.ign"
    cp "$SYNC_B/mod2" "$SYNC_B/new1" "$SYNC_B/x.ign" "$BATS_TEST_TMPDIR/"
    _refuses in-the-way
    [[ "$SYNC_LINE" == *mod2* && "$SYNC_LINE" == *new1* && "$SYNC_LINE" == *x.ign* ]]
    [[ "$SYNC_LINE" == *"Commit the edits to mod2"* ]]
    [[ "$SYNC_LINE" == *"aside (origin now tracks them)"* ]]
    [[ "$SYNC_LINE" != *discard* && "$SYNC_LINE" != *"add -f"* ]]
    for f in mod2 new1 x.ign; do cmp "$SYNC_B/$f" "$BATS_TEST_TMPDIR/$f"; done
    # leg b: an unstaged deletion of a file origin changed refuses before the move
    sync_fixture "$R/b"
    sync_other mod5 'origin mod5' 'A: mod5'
    rm "$SYNC_B/mod5"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" log)"
    _refuses in-the-way
    [[ "$SYNC_LINE" == *"Commit the edits to mod5"* ]]
    [[ "$SYNC_LINE" != *discard* && "$SYNC_LINE" != *"add -f"* ]]
    [ "$(_calls "$BATS_TEST_TMPDIR/w" merge)" = 0 ]
    [ ! -e "$SYNC_B/mod5" ]
}

@test "#1148 merge.autoStash=true: same refusal; the staged change kept" {
    git -C "$SYNC_B" config merge.autoStash true
    sync_other mod2 'origin mod2' 'A: mod2'
    printf 'B edit\n' >> "$SYNC_B/mod2"
    _refuses in-the-way
    [ -z "$(git -C "$SYNC_B" stash list)" ]
    sync_fixture "$R/d"                                              # T1's diverged case
    git -C "$SYNC_B" config merge.autoStash true
    sync_other a.txt 'from A' 'A: a.txt'
    sync_commit "$SYNC_B" b.txt b 'B: b'
    printf 'staged\n' >> "$SYNC_B/st"; git -C "$SYNC_B" add st
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_OUTCOME" = merged ]
    [ "$(_st "$SYNC_B" st)" = 'M ' ]
    [ -z "$(git -C "$SYNC_B" stash list)" ]
}

@test "#1148 HEAD moved: the late commit is kept" {
    sync_other a.txt 'from A' 'A: a.txt'
    sync_commit "$SYNC_B" b.txt b 'B: b'
    o="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" commit-before-merge)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_REASON" = head-moved ]
    [[ "$SYNC_LINE" == *"HEAD moved while the sync ran"* ]]
    git -C "$SYNC_B" cat-file -e HEAD:late.txt
    [ "$(git -C "$SYNC_B" log -1 --format=%s)" = late ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$o" ]
}

@test "#1148 HEAD moved: branch switched before the hold" {
    sync_other a.txt 'from A' 'A: a.txt'
    o="$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)"; m="$(git -C "$SYNC_B" rev-parse refs/heads/main)"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" switch-before-lock)"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_REASON" = head-moved ]
    [ "$(git -C "$SYNC_B" rev-parse refs/heads/main)" = "$m" ]
    [ "$(git -C "$SYNC_ORIGIN" rev-parse refs/heads/main)" = "$o" ]
}

@test "#1148 state refusals: own reason, nothing changed" {
    _leg a; git -C "$SYNC_B" rev-parse HEAD > "$SYNC_B/.git/MERGE_HEAD"
    _refuses mid-merge
    [[ "$SYNC_LINE" == *"(main): the repository is mid-merge."*"Finish the merge by hand"* ]]
    _leg b1; mkdir "$SYNC_B/.git/rebase-merge"
    _refuses mid-rebase
    _leg b2; sync_commit "$SYNC_B" b.txt b 'B: b'
    git -C "$SYNC_B" rebase -q --no-ff -x false HEAD~1 >/dev/null 2>&1 || true
    [ -d "$SYNC_B/.git/rebase-merge" ]
    _refuses mid-rebase
    [[ "$SYNC_LINE" == *"(detached HEAD): the repository is mid-rebase."* ]]
    _leg c; git -C "$SYNC_B" branch up
    sync_commit "$SYNC_B" mod2 'B side' 'B: mod2'
    git -C "$SYNC_B" checkout -q up; sync_commit "$SYNC_B" mod2 'up side' 'up: mod2'; git -C "$SYNC_B" checkout -q main
    git -C "$SYNC_B" rebase -q --apply up >/dev/null 2>&1 || true
    [ -d "$SYNC_B/.git/rebase-apply" ]
    _refuses mid-rebase
    _leg d; git -C "$SYNC_B" checkout -q -b pick
    sync_commit "$SYNC_B" mod2 'pick side' 'pick: mod2'; git -C "$SYNC_B" checkout -q main
    sync_commit "$SYNC_B" mod2 'main side' 'main: mod2'
    git -C "$SYNC_B" cherry-pick pick >/dev/null 2>&1 || true
    [ -e "$SYNC_B/.git/CHERRY_PICK_HEAD" ]
    _refuses mid-cherry-pick
    _leg e; sync_commit "$SYNC_B" mod2 one 'B: one'; c1="$(git -C "$SYNC_B" rev-parse HEAD)"
    sync_commit "$SYNC_B" mod2 two 'B: two'
    git -C "$SYNC_B" revert --no-edit "$c1" >/dev/null 2>&1 || true
    [ -e "$SYNC_B/.git/REVERT_HEAD" ]
    _refuses mid-revert
    _leg f; git -C "$SYNC_B" checkout -q --detach
    _refuses detached
    [[ "$SYNC_LINE" == *"(detached HEAD): HEAD is detached."* ]]
    [[ "$SYNC_LINE" != *"commits not on"* ]]
    sync_fixture "$R/g"; sync_commit "$SYNC_B" b.txt b 'B: b'; : > "$SYNC_B/.git/index.lock"
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$R/g/w" log)"
    _refuses index-lock
    [[ "$SYNC_LINE" == *"another git process holds $SYNC_B/.git/index.lock"* ]]
    [ "$(_calls "$R/g/w" push)" = 0 ]
    unset DEVAGENT_GIT
    _leg h; sync_commit "$SYNC_B" a.txt 'B a' 'B: a.txt'; : > "$SYNC_B/.git/index.lock"
    _refuses index-lock
    sync_fixture "$R/i"; git -c init.defaultBranch=main init -q "$R/i/u"; _sync_ident "$R/i/u"
    sync_commit "$R/i/u" other.txt other 'unrelated'
    git -c init.defaultBranch=main init -q --bare "$R/i/u.git"; git -C "$R/i/u" push -q "$R/i/u.git" main 2>/dev/null
    git -C "$SYNC_B" remote set-url origin "$R/i/u.git"
    _refuses unrelated --no-origin
    [[ "$SYNC_LINE" == *"main and origin/main share no history"* ]]
    _leg j; sync_commit "$SYNC_B" b.txt b 'B: b'
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$R/j/w" lock-at-merge)"
    before="$(sync_snapshot "$SYNC_B")"
    sync_run "$SYNC_B_DOC" Issue-7 30
    [ "$SYNC_REASON" = index-lock ]
    rm "$SYNC_B/.git/index.lock"                                     # the wrapper's stand-in for another process
    [ "$(sync_snapshot "$SYNC_B")" = "$before" ]
    [ "$(_calls "$R/j/w" push)" = 0 ]
}

@test "#1148 busy lock: skipped for this close" {
    sync_commit "$SYNC_B" b.txt b 'B: b'
    _stub_holder "$(_lockdir)"
    export DEVAGENT_DEVDOC_LOCK_DEADLINE=1                           # in the past: one attempt
    local t0=$SECONDS
    _refuses lock-busy
    [ "$SYNC_OUTCOME" = skipped ]
    [[ "$SYNC_LINE" == *"the devDoc lock is busy"*"the next close retries"* ]]
    ! grep -q 'rm -f' "$SYNC_ERR" || false
    [ $((SECONDS - t0)) -lt 10 ]
}

@test "#1148 lock wait spends no network budget" {
    sync_commit "$SYNC_B" b.txt b 'B: b'
    lp="$(_lockdir)"; _stub_holder "$lp"
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=20
    ( sleep 4; rm -rf "$lp" ) >/dev/null 2>&1 3>&- &
    sync_run "$SYNC_B_DOC" Issue-7 3
    [ "$SYNC_OUTCOME" = pushed ] || { echo "$SYNC_LINE" >&2; false; }
}

@test "#1148 other skips" {
    sync_commit "$SYNC_B" b.txt b 'B: b'
    mkdir "$BATS_TEST_TMPDIR/empty"
    SYNC_PATH="$BATS_TEST_TMPDIR/empty" DEVAGENT_GIT="$(command -v git)" _refuses no-timeout
    [ "$SYNC_OUTCOME" = skipped ]
    [[ "$SYNC_LINE" == *"(main): timeout(1) is not on PATH"*"1 commits not on origin/main"* ]]
    export DEVAGENT_GIT; DEVAGENT_GIT="$(sync_git_wrapper "$BATS_TEST_TMPDIR/w" fail-argv:--git-common-dir:128)"
    _refuses lock-location
    [[ "$SYNC_LINE" == *"the devDoc lock location cannot be determined"* ]]
}
