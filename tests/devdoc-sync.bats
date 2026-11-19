#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/devdoc-sync.bats — #1148: cleanup's devDoc sync with origin
# (devdoc_sync in scripts/lib/devdoc-repo.sh), over a real bare origin and two
# clones: A stands in for the other machine, B for this one. Each helper test
# passes B's subdirectory proj/ as devdoc_dir, as a project's devdoc_dir is.
bats_require_minimum_version 1.5.0
load 'helpers/devdoc-sync'

setup() {
    T="$(mktemp -d -t devdoc-sync-XXXXXX)"
    export DEVAGENT_ROOT="$BATS_TEST_DIRNAME/.."
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=2
    sync_fixture "$T"
}
teardown() { chmod -R u+w "$T" 2>/dev/null || true; rm -rf "$T"; }

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
