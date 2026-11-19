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
    ! git -C "$SYNC_B" log -1 --format='%ae %ce' "$M" | grep -q t@example.com
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
    ! git -C "$SYNC_ORIGIN" rev-parse -q --verify refs/heads/heads/main
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
