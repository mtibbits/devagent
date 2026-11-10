#!/usr/bin/env bats
# #749: the devDoc repository lock (scripts/lib/devdoc-repo.sh) — location,
# holder record, reentrancy token, bounded wait, and the printed remedy.
load 'helpers/common'
load 'helpers/devdoc-repo'

setup() {
    devagent_test_setup
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=1
    ( cd "$DEVDOC_DIR" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name Test \
      && git add -A && git commit -q -m seed )
    LIBS=". '$DEVAGENT_ROOT/scripts/lib/io.sh'; . '$DEVAGENT_ROOT/scripts/lib/devdoc-repo.sh'"
    LP="$(devdoc_lock_test_path "$DEVDOC_DIR")"
}
teardown() { devagent_test_teardown; }

_lib() { . "$DEVAGENT_ROOT/scripts/lib/io.sh"; . "$DEVAGENT_ROOT/scripts/lib/devdoc-repo.sh"; }

@test "acquire creates the lock in the common git dir and release removes it" {
    _lib
    mkdir -p "$DEVDOC_DIR/sub"
    [[ "$LP" == */.git/devagent-devdoc.lock ]]
    devdoc_lock_acquire "$DEVDOC_DIR/sub" Issue-1 "/devagent:cleanup testproj Issue-1"
    [ -d "$LP" ]
    [ "$DEVDOC_LOCK_OWNED" = 1 ]
    run cut -d= -f1 "$LP/holder"
    [ "$output" = "$(printf '%s\n' token pid host issue start cmd)" ]
    grep -qx "token=$DEVAGENT_DEVDOC_LOCK_TOKEN" "$LP/holder"
    grep -qx "pid=$$" "$LP/holder"
    grep -qx "issue=Issue-1" "$LP/holder"
    grep -Eqx 'start=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$LP/holder"
    grep -Eqx 'host=.+' "$LP/holder"
    grep -Eqx 'cmd=.+' "$LP/holder"
    devdoc_lock_release
    [ ! -e "$LP" ]
    [ -z "${DEVAGENT_DEVDOC_LOCK_TOKEN:-}" ]
}

@test "a linked worktree resolves the same lock" {
    _lib
    git -C "$DEVDOC_DIR" worktree add -q "$DEVAGENT_TMP/wt" -b wt
    [ "$(devdoc_lock_path "$DEVAGENT_TMP/wt")" = "$LP" ]
    devdoc_lock_acquire "$DEVAGENT_TMP/wt" Issue-1 /x
    [ -d "$LP" ]
    devdoc_lock_release
    [ ! -e "$LP" ]
}

@test "outside git the side lock is used" {
    _lib
    d="$DEVAGENT_TMP/plain"; mkdir -p "$d"
    devdoc_lock_acquire "$d" - /x
    [ -d "$d/.devagent-wbs.lock" ]
    [ "$(devdoc_lock_path "$d")" = "$(cd "$d" && pwd -P)/.devagent-wbs.lock" ]
    devdoc_lock_release
    [ ! -e "$d/.devagent-wbs.lock" ]
}

@test "a .git entry with a failing rev-parse refuses instead of taking the side lock" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$DEVAGENT_TMP/git-broken"; chmod +x "$DEVAGENT_TMP/git-broken"
    DEVAGENT_GIT="$DEVAGENT_TMP/git-broken" run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-1 '/devagent:cleanup testproj Issue-1'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot determine the devdoc lock for $DEVDOC_DIR"* ]]
    [[ "$output" == *"re-run /devagent:cleanup testproj Issue-1"* ]]
    [ ! -e "$LP" ]
    [ ! -e "$DEVDOC_DIR/.devagent-wbs.lock" ]
}

@test "a child with the matching token neither acquires nor releases" {
    _lib
    devdoc_lock_acquire "$DEVDOC_DIR" Issue-1 /x
    cp "$LP/holder" "$DEVAGENT_TMP/holder.before"
    run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-2 /x || exit 9; echo owned=\$DEVDOC_LOCK_OWNED; devdoc_lock_release"
    [ "$status" -eq 0 ]
    [[ "$output" == *"owned=0"* ]]
    [ -d "$LP" ]
    cmp "$LP/holder" "$DEVAGENT_TMP/holder.before"
    devdoc_lock_release
}

@test "a child with a non-matching token acquires on its own" {
    DEVAGENT_DEVDOC_LOCK_TOKEN=1.2.3 run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-2 /x || exit 9; echo me=\$\$; cat '$LP/holder'; devdoc_lock_release"
    [ "$status" -eq 0 ]
    me="$(printf '%s\n' "$output" | sed -n 's/^me=//p')"
    [ -n "$me" ]
    [[ "$output" == *"pid=$me"* ]]
    [ ! -e "$LP" ]
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-3
    DEVAGENT_DEVDOC_LOCK_TOKEN=1.2.3 run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-2 /x"
    [ "$status" -eq 1 ]
}

@test "timeout names the path, the holder and the remedy" {
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-1 '/devagent:cleanup testproj Issue-1'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"devdoc lock $LP is held by pid 4242 on otherhost for Issue-2 since 2026-11-01T10:00:00Z (cleanup.sh)"* ]]
    [[ "$output" == *"gave up after 1s (DEVAGENT_DEVDOC_LOCK_TIMEOUT)"* ]]
    [[ "$output" == *"rm -f '$LP/holder' && rmdir '$LP'"* ]]
    [[ "$output" == *"then re-run /devagent:cleanup testproj Issue-1"* ]]
    [[ "$output" != *"rm -rf"* ]]
    [ -d "$LP" ]
}

@test "the printed remedy, run verbatim, frees the lock and nothing else" {
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-1 /x"
    [ "$status" -eq 1 ]
    remedy="$(printf '%s\n' "$output" | grep -o "rm -f '[^']*' && rmdir '[^']*'")"
    [ -n "$remedy" ]
    bash -c "$remedy"
    [ ! -e "$LP" ]
    run bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-1 /x && devdoc_lock_release"
    [ "$status" -eq 0 ]
    # a lock dir holding anything besides the record is not freed by the remedy
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    : > "$LP/planted"
    run bash -c "$remedy"
    [ "$status" -ne 0 ]
    [ -e "$LP/planted" ]
}

@test "a waiter gets the lock when the holder releases" {
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    DEVAGENT_DEVDOC_LOCK_TIMEOUT=60 bash -c "$LIBS; devdoc_lock_acquire '$DEVDOC_DIR' Issue-1 /x; rc=\$?; devdoc_lock_release; exit \$rc" \
        2> "$DEVAGENT_TMP/waiter.err" 3>&- &
    waiter=$!
    n=0
    until grep -q 'waiting for devdoc lock' "$DEVAGENT_TMP/waiter.err" 2>/dev/null; do
        n=$((n + 1)); [ "$n" -lt 300 ] || { kill "$waiter"; false; }
        sleep 0.1
    done
    rm -f "$LP/holder" && rmdir "$LP"
    wait "$waiter"
    [ "$(grep -c 'waiting for devdoc lock' "$DEVAGENT_TMP/waiter.err")" -eq 1 ]
    grep -q "waiting for devdoc lock $LP (held by pid 4242 on otherhost for Issue-2 since 2026-11-01T10:00:00Z, cleanup.sh)" "$DEVAGENT_TMP/waiter.err"
    [ ! -e "$LP" ]
}

@test "an invalid timeout warns once and uses the default" {
    for bad in abc 123456; do
        DEVAGENT_DEVDOC_LOCK_TIMEOUT="$bad" run bash -c "$LIBS; for i in 1 2; do devdoc_lock_acquire '$DEVDOC_DIR' - /x || exit 9; devdoc_lock_release; done; echo t=\$DEVDOC_LOCK_TIMEOUT_S"
        [ "$status" -eq 0 ]
        [ "$(printf '%s\n' "$output" | grep -c 'DEVAGENT_DEVDOC_LOCK_TIMEOUT')" -eq 1 ]
        [[ "$output" == *"t=120"* ]]
    done
}

@test "release by a non-owner leaves the lock" {
    _lib
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    devdoc_lock_release
    [ -f "$LP/holder" ]
    DEVDOC_LOCK_OWNED=1 DEVAGENT_DEVDOC_LOCK_TOKEN=9.9.9 devdoc_lock_release
    [ -f "$LP/holder" ]
    grep -qx 'pid=4242' "$LP/holder"
}
