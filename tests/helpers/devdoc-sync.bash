. "$(dirname "${BASH_SOURCE[0]}")/../lib/hermetic-env.bash"
# tests/helpers/devdoc-sync.bash — fixtures for #1148, cleanup's devDoc sync with
# origin: a bare origin and two clones (A, the other machine; B, this machine), a
# state snapshot, a strict driver for devdoc_sync, and a DEVAGENT_GIT stand-in
# that reaches the states a normal close does not. Loaded by tests/devdoc-sync.bats,
# tests/cleanup.bats and tests/status.bats. Every function takes its root
# explicitly; nothing here reads the library under test.
# shellcheck disable=SC2034  # SYNC_* are read by the bats files that load this helper

_sync_ident() { git -C "$1" config user.email t@example.com && git -C "$1" config user.name Test; }

# sync_fixture <root> — <root>/origin.git (bare, main) holding the seed, cloned to
# <root>/a and <root>/b. Sets SYNC_ORIGIN SYNC_A SYNC_B and SYNC_B_DOC=$SYNC_B/proj
# (every helper test passes that subdirectory as devdoc_dir). The seed is
# proj/WBS.md hd/keep1 hd/hdel mod2 del3 mod5 st ed and a .gitignore of *.ign.
sync_fixture() {
    local root="$1" f
    SYNC_ORIGIN="$root/origin.git" SYNC_A="$root/a" SYNC_B="$root/b" SYNC_B_DOC="$root/b/proj"
    git -c init.defaultBranch=main init -q --bare "$SYNC_ORIGIN"
    git -c init.defaultBranch=main init -q "$SYNC_A"
    _sync_ident "$SYNC_A"
    git -C "$SYNC_A" remote add origin "$SYNC_ORIGIN"
    mkdir -p "$SYNC_A/proj" "$SYNC_A/hd"
    printf '%s\n' '# proj WBS' '- [ ] leaf one' '- [ ] leaf two' > "$SYNC_A/proj/WBS.md"
    for f in hd/keep1 hd/hdel mod2 del3 mod5 st ed; do printf '%s seed\n' "$f" > "$SYNC_A/$f"; done
    printf '*.ign\n' > "$SYNC_A/.gitignore"
    git -C "$SYNC_A" add -A
    git -C "$SYNC_A" commit -q -m seed
    git -C "$SYNC_A" push -q -u origin main 2>/dev/null
    git clone -q "$SYNC_ORIGIN" "$SYNC_B"
    _sync_ident "$SYNC_B"
}

# sync_commit <clone> <path> <text> <msg> — write <text> to <path> and commit it.
sync_commit() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add -- "$2"
    git -C "$1" commit -q -m "$4"
}

# sync_other <path> <text> <msg> — sync_commit in A, then push it to origin.
sync_other() {
    sync_commit "$SYNC_A" "$@"
    git -C "$SYNC_A" push -q origin main 2>/dev/null
}

# sync_snapshot <clone> [--no-origin] — print everything a sync could change:
# HEAD, the index, the porcelain (untracked and ignored included), the stash, the
# in-progress-operation markers, the devDoc lock dir and origin's main. Equal
# snapshots mean nothing changed (L44).
sync_snapshot() {
    local c="$1" gd cd m
    gd="$(git -C "$c" rev-parse --absolute-git-dir)"
    cd="$(cd "$c" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    printf 'HEAD %s\n' "$(git -C "$c" rev-parse -q --verify HEAD || echo none)"
    printf 'branch %s\n' "$(git -C "$c" symbolic-ref -q HEAD || echo detached)"
    git -C "$c" ls-files -s
    printf -- '--status\n'
    git -C "$c" status --porcelain --untracked-files=all --ignored
    printf -- '--stash\n'
    git -C "$c" stash list
    for m in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply index.lock; do
        [ -e "$gd/$m" ] && printf 'marker %s\n' "$m"
    done
    [ -e "$cd/devagent-devdoc.lock" ] && printf 'marker devagent-devdoc.lock\n'
    [ "${2:-}" = --no-origin ] || printf 'origin %s\n' "$(git -C "$SYNC_ORIGIN" rev-parse -q --verify refs/heads/main || echo none)"
}

# sync_run <dir> <issue> <budget> — run devdoc_sync <dir> <issue> <budget> the way
# cleanup does: a fresh bash under set -euo pipefail that sources io.sh and
# devdoc-repo.sh, from <dir>. DEVAGENT_GIT passes through; $SYNC_PATH, when set,
# is the call's PATH. Sets SYNC_RC SYNC_OUTCOME SYNC_REASON SYNC_LINE; stderr goes
# to $SYNC_ERR. rc 1 when the driver aborts or the line holds a newline.
sync_run() {
    local out rc=0
    out="$(mktemp)"
    SYNC_ERR="${SYNC_ERR:-${BATS_TEST_TMPDIR:-/tmp}/sync.err}"
    SYNC_RC="" SYNC_OUTCOME="" SYNC_REASON="" SYNC_LINE=""
    env ${SYNC_PATH:+PATH="$SYNC_PATH"} "$BASH" -c '
        set -euo pipefail
        . "$DEVAGENT_ROOT/scripts/lib/io.sh"
        . "$DEVAGENT_ROOT/scripts/lib/devdoc-repo.sh"
        cd "$1"
        r=0
        devdoc_sync "$1" "$2" "$3" || r=$?
        printf "%s\0" "$r" "$DEVDOC_SYNC_OUTCOME" "$DEVDOC_SYNC_REASON" "$DEVDOC_SYNC_LINE" > "$4"
    ' _ "$1" "$2" "$3" "$out" 2>"$SYNC_ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$out"; echo "sync_run: the driver exited $rc" >&2; cat "$SYNC_ERR" >&2; return 1
    fi
    { IFS= read -r -d '' SYNC_RC; IFS= read -r -d '' SYNC_OUTCOME
      IFS= read -r -d '' SYNC_REASON; IFS= read -r -d '' SYNC_LINE; } < "$out" || true
    rm -f "$out"
    case "$SYNC_LINE" in *$'\n'*) echo "sync_run: the line holds a newline: $SYNC_LINE" >&2; return 1 ;; esac
    return 0
}

# sync_git_wrapper <dir> <mode>[+<mode>…] — write <dir>/git, a DEVAGENT_GIT
# stand-in, and print its path. Every call appends its subcommand (found per
# argv word by the -C/-c walk, L204) to <dir>/calls; a network call (ls-remote,
# fetch, push) also appends `start <sub> <µs>` and `end <sub> <µs> ok|term`.
# Modes:
#   log                     record only
#   commit-before-merge     on merge: commit late.txt, then the real merge
#   partway:<held>[:skip=<p>]  on merge: write the M/A paths of HEAD..<target> and
#                           delete the D paths (except <held> and <p>), then print
#                           git's unlink error for <held> and exit 1
#   unlink-warn:<p>         the real merge, then <p> recreated from ORIG_HEAD and
#                           git's unlink warning; exit 0
#   checkout-fail           on checkout: exit 1, do nothing
#   fetch-race              the real fetch, then a ref-lock error and exit 1
#   fetch-fail-once         the first fetch exits 128; later ones are real
#   fetch-fail-always       every fetch exits 128
#   push-race               push from A, then the real push
#   push-race-fetched       push from A, fetch in B, then the real push
#   switch-before-lock      after ls-remote: checkout -q -b other in the repo
#   lock-at-merge           on merge: create <git dir>/index.lock, then the real merge
#   slow:<sub>=<s>[,…]      sleep <s> on <sub>; slow:<s> sleeps on every network call.
#                           TERM logs `end … term` and exits 143
#   fail:<sub>:<rc>         on <sub>: print `fatal: synthetic <sub> failure`, exit <rc>
#   fail-argv:<word>:<rc>   the same when any argv word is <word>
sync_git_wrapper() {
    local d="$1" modes="$2" w real
    mkdir -p "$d"
    w="$d/git"; real="$(command -v git)"
    {
        printf '#!%s\n' "$BASH"
        printf 'd=%q; real=%q; modes=%q; other=%q\n' "$d" "$real" "$modes" "${SYNC_A:-}"
        cat <<'EOF'
dir="$PWD"; sub=""; i=1
while [ "$i" -le "$#" ]; do
    a="${!i}"
    case "$a" in
        -C) i=$((i + 1)); t="${!i}"; case "$t" in /*) dir="$t" ;; *) dir="$dir/$t" ;; esac ;;
        -c) i=$((i + 1)) ;;
        -*) ;;
        *) sub="$a"; break ;;
    esac
    i=$((i + 1))
done
printf '%s\n' "$sub" >> "$d/calls"
net=0
case "$sub" in ls-remote|fetch|push) net=1 ;; esac
_end() { [ "$net" = 1 ] && printf 'end %s %s %s\n' "$sub" "${EPOCHREALTIME//[.,]/}" "$1" >> "$d/calls"; return 0; }
[ "$net" = 1 ] && printf 'start %s %s\n' "$sub" "${EPOCHREALTIME//[.,]/}" >> "$d/calls"
_real() { "$real" "$@"; }
_fin() { local rc="$1"; _end ok; exit "$rc"; }
_race_push() {
    printf 'race %s\n' "${EPOCHREALTIME}" > "$other/race.txt"
    _real -C "$other" add race.txt && _real -C "$other" commit -q -m race && _real -C "$other" push -q origin main 2>/dev/null
}
target="${!#}"
post=""
IFS='+' read -r -a ms <<< "$modes"
for m in "${ms[@]}"; do
    case "$m" in
        log) ;;
        commit-before-merge)
            if [ "$sub" = merge ]; then
                printf 'late\n' > "$dir/late.txt"
                _real -C "$dir" add late.txt && _real -C "$dir" commit -q -m late
            fi ;;
        partway:*)
            [ "$sub" = merge ] || continue
            spec="${m#partway:}"; held="${spec%%:*}"; skip=""
            case "$spec" in *:skip=*) skip="${spec#*:skip=}" ;; esac
            while IFS=$'\t' read -r st p; do
                [ "$p" = "$held" ] || [ "$p" = "$skip" ] && continue
                case "$st" in
                    M|A) mkdir -p "$(dirname "$dir/$p")"; _real -C "$dir" show "$target:$p" > "$dir/$p" ;;
                    D) rm -f -- "$dir/$p" ;;
                esac
            done < <(_real -C "$dir" diff --no-renames --name-status HEAD "$target")
            printf "error: unable to unlink old '%s': Permission denied\n" "$held" >&2
            _fin 1 ;;
        unlink-warn:*) [ "$sub" = merge ] && post="$m" ;;
        checkout-fail) [ "$sub" = checkout ] && _fin 1 ;;
        fetch-race) [ "$sub" = fetch ] && post=fetch-race ;;
        fetch-fail-once)
            if [ "$sub" = fetch ] && [ ! -e "$d/fetch-failed-once" ]; then
                : > "$d/fetch-failed-once"; echo "fatal: synthetic fetch failure" >&2; _fin 128
            fi ;;
        fetch-fail-always) [ "$sub" = fetch ] && { echo "fatal: synthetic fetch failure" >&2; _fin 128; } ;;
        push-race) [ "$sub" = push ] && _race_push ;;
        push-race-fetched) [ "$sub" = push ] && { _race_push; _real -C "$dir" fetch -q origin; } ;;
        switch-before-lock) [ "$sub" = ls-remote ] && post=switch ;;
        lock-at-merge) [ "$sub" = merge ] && : > "$(_real -C "$dir" rev-parse --absolute-git-dir)/index.lock" ;;
        slow:*)
            [ "$net" = 1 ] || continue
            spec="${m#slow:}"; secs=""
            case "$spec" in
                *=*) IFS=',' read -r -a kv <<< "$spec"
                     for e in "${kv[@]}"; do [ "${e%%=*}" = "$sub" ] && secs="${e#*=}"; done ;;
                *) secs="$spec" ;;
            esac
            if [ -n "$secs" ]; then
                sleep "$secs" & sp=$!
                trap '_end term; kill "$sp" 2>/dev/null; exit 143' TERM
                wait "$sp"
                trap - TERM
            fi ;;
        fail:*)
            spec="${m#fail:}"
            [ "${spec%%:*}" = "$sub" ] && { echo "fatal: synthetic $sub failure" >&2; _fin "${spec#*:}"; } ;;
        fail-argv:*)
            spec="${m#fail-argv:}"; word="${spec%:*}"
            for a in "$@"; do
                [ "$a" = "$word" ] && { echo "fatal: synthetic $sub failure" >&2; _fin "${spec##*:}"; }
            done ;;
    esac
done
trap '_end term; exit 143' TERM
rc=0
_real "$@" || rc=$?
case "$post" in
    fetch-race) [ "$rc" -eq 0 ] && { echo "error: cannot lock ref 'refs/remotes/origin/main'" >&2; rc=1; } ;;
    switch) _real -C "$dir" checkout -q -b other ;;
    unlink-warn:*)
        if [ "$rc" -eq 0 ]; then
            p="${post#unlink-warn:}"
            mkdir -p "$(dirname "$dir/$p")"
            _real -C "$dir" show "ORIG_HEAD:$p" > "$dir/$p"
            printf "warning: unable to unlink '%s': Permission denied\n" "$p" >&2
        fi ;;
esac
_fin "$rc"
EOF
    } > "$w"
    chmod +x "$w"
    printf '%s\n' "$w"
}
