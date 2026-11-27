#!/usr/bin/env bash
# scripts/lib/devdoc-repo.sh — the devDoc repository discipline (#749).
# Every devagent write into the shared devDoc repository goes through here:
# read-only git calls that never take git's optional index lock, the ONE
# definition of the paths a cleanup owns, the mid-merge check, and the
# best-effort one-folder commit of filing and ship (#1055).
# Needs io.sh (die/warn/info). Safe to source multiple times.

: "${DEVAGENT_GIT:=git}"
# #1148: the devDoc sync reuses the bounded network calls and git's merge parser. Both
# files define functions only.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/upstream.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/merge-forward.sh"

# devdoc_git_ro <git args…> — a READ-ONLY git call. GIT_OPTIONAL_LOCKS=0 stops
# `status` from refreshing and rewriting the index (taking index.lock), so a
# read can never collide with another session's add/commit.
devdoc_git_ro() { GIT_OPTIONAL_LOCKS=0 "$DEVAGENT_GIT" "$@"; }

# devdoc_repo_top <path> — canonical (pwd -P) toplevel of the git repository
# holding the nearest EXISTING ancestor of <path> (the path itself may not
# exist yet). rc 1 and no output outside a repo. promote-potholes.sh's
# _repo_of is this helper (one home for the rule, register Issue-565).
devdoc_repo_top() {
    local d="${1:-}" top
    while [ -n "$d" ] && [ ! -d "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
    [ -d "$d" ] || return 1
    top="$(devdoc_git_ro -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1          # `cd ""` would succeed in place (Issue-571)
    ( cd "$top" 2>/dev/null && pwd -P )
}

# _devdoc_rel <repo_top> <path> — <path> relative to <repo_top> (from
# devdoc_repo_top); rc 1 when <path> is outside it. <path>'s parent must exist.
# Git derives both the prefix and the toplevel, never a string compare of a
# typed path: on a case-insensitive filesystem a config path in another
# letter case (or a junction / 8.3 form) names the same directory, and
# `pwd -P` keeps the typed form while git reports the on-disk one.
_devdoc_rel() {
    local top="$1" p="$2" d leaf="" pre t
    if [ -d "$p" ]; then d="$p"; else d="$(dirname "$p")"; leaf="$(basename "$p")"; fi
    [ -d "$d" ] || return 1
    t="$(devdoc_repo_top "$d")" || return 1
    [ "$t" = "$top" ] || return 1
    pre="$(devdoc_git_ro -C "$d" rev-parse --show-prefix 2>/dev/null)" || return 1
    pre="${pre%/}"
    if [ -n "$leaf" ]; then pre="${pre:+$pre/}$leaf"; fi
    printf '%s\n' "${pre:-.}"
}

# devdoc_owned_pathspecs <devdoc_dir> <issue_dir> — fill DEVDOC_OWNED=() with
# the paths a cleanup of <issue_dir> owns, as `:(top,literal)<repo-rel>`
# pathspecs (cwd-independent, no glob magic): the issue dir, plus
# <devdoc_dir>/WBS.md when it has changes (the reconcile's output, and any hand
# edit riding with it). THE ONE DEFINITION OF THE OWNED SET — a new owned path
# (#754's record file) joins here. rc 1 outside a repo; rc 2 when the issue dir
# is outside the repo holding devdoc_dir.
devdoc_owned_pathspecs() {
    local devdoc_dir="$1" issue_dir="$2" top rel wbs
    DEVDOC_OWNED=()
    top="$(devdoc_repo_top "$devdoc_dir")" || return 1
    rel="$(_devdoc_rel "$top" "$issue_dir")" || return 2
    [ "$rel" != . ] || return 2        # the issue dir IS the repo: no narrower scope exists
    DEVDOC_OWNED+=(":(top,literal)$rel")
    if rel="$(_devdoc_rel "$top" "$devdoc_dir/WBS.md")"; then
        wbs=":(top,literal)$rel"
        if [ -n "$(devdoc_git_ro -C "$top" status --porcelain -- "$wbs")" ]; then
            DEVDOC_OWNED+=("$wbs")
        fi
    fi
}

# DEVDOC_UNOWNED_WARN_DAYS — a unit with no file newer than this many days,
# and not in flight, turns the unowned report into a warning.
DEVDOC_UNOWNED_WARN_DAYS=7

# _devdoc_unit_in_flight <project> <devdoc_dir> <unit> — rc 0 when <unit> is
# work some session still owns: a capture not yet filed (no filed.toml), or an
# issue dir with a [context] table, a parked entry, or the shared active_issue.
# Top-level files are never in flight. Needs state.sh.
_devdoc_unit_in_flight() {
    local project="$1" devdoc_dir="$2" unit="$3" name
    case "$unit" in
        Captures/*/) [ ! -e "$devdoc_dir/${unit}filed.toml" ]; return ;;
        */) name="${unit%/}" ;;
        *) return 1 ;;
    esac
    state_context_has "$project" "$name" && return 0
    state_list_parked "$project" | grep -qxF -- "$name" && return 0
    [ "$(state_get "$project" active_issue 2>/dev/null || true)" = "$name" ]
}

# devdoc_unowned_report <project> <devdoc_dir> <issue> [<exclude pathspec>…]
# — report (never commit) the changed paths under <devdoc_dir> this cleanup
# does not own: DEVDOC_OWNED (from devdoc_owned_pathspecs) and the exclude
# pathspecs (the register layer files, the drain's to commit) are left out, as
# are devagent's own WBS lock/temp files. Paths are grouped into units —
# `Captures/<slug>/`, `<first component>/`, or a top-level file — and counted
# on ONE line: info, or warn when a unit is older than
# DEVDOC_UNOWNED_WARN_DAYS and not in flight. Prints nothing when there are
# none. Runs from <devdoc_dir>.
devdoc_unowned_report() {
    local project="$1" devdoc_dir="$2" issue="$3"
    shift 3
    local prefix entry xy p skip_next=0 o orel unit u stale=() units=() owned=() n shown more msg
    local -A seen=()
    prefix="$(cd "$devdoc_dir" && devdoc_git_ro rev-parse --show-prefix 2>/dev/null)" || return 0
    for o in "${DEVDOC_OWNED[@]}"; do
        orel="${o#:(top,literal)}"; owned+=("${orel#"$prefix"}")
    done
    while IFS= read -r -d '' entry; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi   # a rename's source path
        xy="${entry:0:2}"; p="${entry:3}"
        case "$xy" in R*|C*|?R|?C) skip_next=1 ;; esac
        p="${p#"$prefix"}"
        for orel in "${owned[@]}"; do
            case "$p" in "$orel"|"$orel"/*) continue 2 ;; esac
        done
        case "/$p" in */.devagent-wbs[-.]*) continue ;; esac
        case "$p" in
            Captures/*/*) unit="${p#Captures/}"; unit="Captures/${unit%%/*}/" ;;
            */*) unit="${p%%/*}/" ;;
            *) unit="$p" ;;
        esac
        [ -n "${seen[$unit]:-}" ] && continue
        seen[$unit]=1; units+=("$unit")
    done < <(cd "$devdoc_dir" && devdoc_git_ro status --porcelain -z --untracked-files=all -- . "$@")
    n="${#units[@]}"
    [ "$n" -gt 0 ] || return 0
    for u in "${units[@]}"; do
        # OLD: has a file, and none newer than the bound; nothing on disk is never old.
        [ -n "$(find "$devdoc_dir/$u" -type f -print -quit 2>/dev/null)" ] || continue
        [ -z "$(find "$devdoc_dir/$u" -type f -mtime "-$DEVDOC_UNOWNED_WARN_DAYS" -print -quit 2>/dev/null)" ] || continue
        _devdoc_unit_in_flight "$project" "$devdoc_dir" "$u" && continue
        stale+=("$u")
    done
    shown="$(printf '%s, ' "${units[@]:0:5}")"; shown="${shown%, }"
    more=""; [ "$n" -le 5 ] || more=" (+$((n - 5)) more)"
    msg="cleanup: $n unowned path(s) under $devdoc_dir left uncommitted (not $issue's): $shown$more"
    if [ "${#stale[@]}" -gt 0 ]; then
        u="$(printf '%s, ' "${stale[@]:0:5}")"; u="${u%, }"
        [ "${#stale[@]}" -le 5 ] || u="$u (+$((${#stale[@]} - 5)) more)"
        warn "$msg - older than $DEVDOC_UNOWNED_WARN_DAYS days and not in flight: $u; commit or remove them by hand"
    else
        info "$msg"
    fi
}

# ---------------------------------------------------------------------------
# The devDoc repository lock (#749; spec §3.3 "devDoc repository lock").
# ONE mkdir lock per repository, in the git COMMON dir so every linked worktree
# and every environment (Git Bash, WSL) sharing the repository resolves the
# same directory. Outside git: the side lock <devdoc_dir>/.devagent-wbs.lock.
# Reentrant through DEVAGENT_DEVDOC_LOCK_TOKEN: a child of the holder whose
# token matches the record neither acquires nor releases. No trap here —
# callers put devdoc_lock_release into their ONE EXIT trap.
# ---------------------------------------------------------------------------

# := so a re-source never forgets a lock this process holds.
: "${DEVDOC_LOCK_OWNED:=0}" "${DEVDOC_LOCK_PATH:=}" "${_DEVDOC_TIMEOUT_WARNED:=0}"

# devdoc_in_git <dir> — rc 0: in a git repository (prints the canonical common
# dir); rc 1: no .git entry at <dir> or any ancestor; rc 2: a .git entry
# exists but rev-parse failed there (absent and cannot-determine are
# different states, register Issue-243 — never guessed as "outside git").
devdoc_in_git() {
    local dir="$1" d c up
    # resolve from the nearest EXISTING ancestor (a devdoc_dir not created yet)
    while [ -n "$dir" ] && [ ! -d "$dir" ]; do
        up="$(dirname "$dir")"; [ "$up" != "$dir" ] || break; dir="$up"
    done
    if c="$(cd "$dir" 2>/dev/null && c="$(devdoc_git_ro rev-parse --git-common-dir 2>/dev/null)" \
            && [ -n "$c" ] && cd "$c" && pwd -P)" && [ -n "$c" ]; then
        printf '%s\n' "$c"
        return 0
    fi
    d="$(cd "$dir" 2>/dev/null && pwd -P)" || d="$dir"
    while [ -n "$d" ]; do
        [ -e "$d/.git" ] && return 2
        up="$(dirname "$d")"
        [ "$up" != "$d" ] || break       # /, ., or a drive root: no further ancestor
        d="$up"
    done
    return 1
}

# devdoc_lock_path <devdoc_dir> — the lock directory for <devdoc_dir>.
# rc 2 (no output) when a .git entry exists but rev-parse fails; rc 3 when
# <devdoc_dir> is outside git and does not exist (the side lock needs it).
devdoc_lock_path() {
    local c rc=0
    c="$(devdoc_in_git "$1")" || rc=$?
    case "$rc" in
        0) printf '%s/devagent-devdoc.lock\n' "$c" ;;
        1) c="$(cd "$1" 2>/dev/null && pwd -P)" && [ -n "$c" ] || return 3   # the side lock needs the dir
           printf '%s/.devagent-wbs.lock\n' "$c" ;;
        *) return 2 ;;
    esac
}

# _devdoc_lock_timeout — resolve DEVAGENT_DEVDOC_LOCK_TIMEOUT (seconds,
# ^[0-9]{1,5}$, default 60, 0 = one attempt) into DEVDOC_LOCK_TIMEOUT_S; an
# invalid value warns once per process and uses the default.
_devdoc_lock_timeout() {
    local v="${DEVAGENT_DEVDOC_LOCK_TIMEOUT:-}"
    if [ -z "$v" ]; then
        DEVDOC_LOCK_TIMEOUT_S=60
    elif [[ "$v" =~ ^[0-9]{1,5}$ ]]; then
        DEVDOC_LOCK_TIMEOUT_S=$((10#$v))
    else
        DEVDOC_LOCK_TIMEOUT_S=60
        if [ "$_DEVDOC_TIMEOUT_WARNED" -eq 0 ]; then
            warn "DEVAGENT_DEVDOC_LOCK_TIMEOUT='$v' is not a whole number of seconds (0-99999) - using 60"
            _DEVDOC_TIMEOUT_WARNED=1
        fi
    fi
}

# devdoc_lock_deadline_start — export DEVAGENT_DEVDOC_LOCK_DEADLINE (epoch
# seconds) as now + the bound, unless an earlier valid deadline is already
# set. A run that waits on the lock more than once (cleanup) calls this once,
# before its first lock section: every acquire in it and in its children then
# gives up by that one deadline, so the run's waits total at most the bound.
devdoc_lock_deadline_start() {
    local d="${DEVAGENT_DEVDOC_LOCK_DEADLINE:-}" mine
    _devdoc_lock_timeout
    bounded_now_us
    mine=$(( BOUNDED_NOW_US / 1000000 + DEVDOC_LOCK_TIMEOUT_S ))
    if [[ "$d" =~ ^[0-9]{1,12}$ ]] && [ "$((10#$d))" -lt "$mine" ]; then
        mine=$((10#$d))
    fi
    export DEVAGENT_DEVDOC_LOCK_DEADLINE="$mine"
}

# _devdoc_lock_field <lock path> <key> — one value from the holder record.
_devdoc_lock_field() {
    sed -n "s/^$2=//p" "$1/holder" 2>/dev/null | head -n 1
}

# _devdoc_lock_holder <lock path> — set _H_PID _H_HOST _H_ISSUE _H_START
# _H_CMD (first value per key, read in one pass); rc 1 when the record is
# absent or unreadable.
_devdoc_lock_holder() {
    local line k v
    _H_PID=; _H_HOST=; _H_ISSUE=; _H_START=; _H_CMD=
    [ -r "$1/holder" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            pid) [ -n "$_H_PID" ] || _H_PID="$v" ;;
            host) [ -n "$_H_HOST" ] || _H_HOST="$v" ;;
            issue) [ -n "$_H_ISSUE" ] || _H_ISSUE="$v" ;;
            start) [ -n "$_H_START" ] || _H_START="$v" ;;
            cmd) [ -n "$_H_CMD" ] || _H_CMD="$v" ;;
        esac
    done < "$1/holder" 2>/dev/null
    [ -n "$_H_PID" ] && [ -n "$_H_START" ]
}

# devdoc_lock_acquire <devdoc_dir> <issue|-> <rerun text> — rc 0 holding the
# lock (DEVDOC_LOCK_OWNED=1, DEVAGENT_DEVDOC_LOCK_TOKEN exported) or reentrant
# (the env token equals the record's: DEVDOC_LOCK_OWNED=0, nothing created);
# rc 1 timed out; rc 2 no lock location. rc 1/2 print their message and never
# die — the caller decides what a refusal means.
devdoc_lock_acquire() {
    local devdoc_dir="$1" issue="${2:--}" rerun="$3" path rc=0 tok end dl bound waited=0
    path="$(devdoc_lock_path "$devdoc_dir")" || rc=$?
    if [ "$rc" -eq 3 ]; then
        info "cannot determine the devdoc lock for $devdoc_dir: it is outside git and does not exist - create it or fix the configured devdoc_dir, then re-run $rerun"
        return 2
    elif [ "$rc" -ne 0 ]; then
        info "cannot determine the devdoc lock for $devdoc_dir: a .git entry exists but git rev-parse failed there - fix git (PATH, safe.directory) and re-run $rerun"
        return 2
    fi
    tok="${DEVAGENT_DEVDOC_LOCK_TOKEN:-}"
    if [[ "$tok" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$(_devdoc_lock_field "$path" token)" = "$tok" ]; then
        DEVDOC_LOCK_OWNED=0; DEVDOC_LOCK_PATH="$path"
        return 0
    fi
    # The bound is ELAPSED time (#749 red-team: counting 0.2 s polls overshot
    # by about a quarter), capped by the run's shared deadline when one is set.
    _devdoc_lock_timeout
    bounded_now_us
    end=$(( BOUNDED_NOW_US + DEVDOC_LOCK_TIMEOUT_S * 1000000 ))
    bound="${DEVDOC_LOCK_TIMEOUT_S}s (DEVAGENT_DEVDOC_LOCK_TIMEOUT)"
    dl="${DEVAGENT_DEVDOC_LOCK_DEADLINE:-}"
    if [[ "$dl" =~ ^[0-9]{1,12}$ ]] && [ "$((10#$dl * 1000000))" -lt "$end" ]; then
        end=$((10#$dl * 1000000))
        bound="this run's shared lock deadline (DEVAGENT_DEVDOC_LOCK_TIMEOUT across all of its waits)"
    fi
    until mkdir "$path" 2>/dev/null; do
        bounded_now_us
        if [ "$BOUNDED_NOW_US" -ge "$end" ]; then
            if _devdoc_lock_holder "$path"; then
                info "devdoc lock $path is held by pid $_H_PID on $_H_HOST for $_H_ISSUE since $_H_START ($_H_CMD) - gave up after $bound. A killed run can leave it held. Only if no devagent run started at $_H_START is still running on $_H_HOST (check on that host, in that environment: the pid is that shell's own, not a Windows pid), remove it with: rm -f '$path/holder' && rmdir '$path' - then re-run $rerun"
            else
                info "devdoc lock $path is held (holder unknown: no readable record) - gave up after $bound. A killed run can leave it held, and a run that is just taking it has not written its record yet. Only if no devagent run is still running against this repository, remove it with: rm -f '$path/holder' && rmdir '$path' - then re-run $rerun"
            fi
            return 1
        fi
        if [ "$waited" -eq 0 ]; then
            if _devdoc_lock_holder "$path"; then
                info "waiting for devdoc lock $path (held by pid $_H_PID on $_H_HOST for $_H_ISSUE since $_H_START, $_H_CMD)"
            else
                info "waiting for devdoc lock $path (holder unknown)"
            fi
            waited=1
        fi
        sleep 0.2
    done
    tok="$$.$(date +%s).$RANDOM"
    printf 'token=%s\npid=%s\nhost=%s\nissue=%s\nstart=%s\ncmd=%s\n' \
        "$tok" "$$" "$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")" "$issue" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_io_progname)" > "$path/holder"
    DEVDOC_LOCK_OWNED=1; DEVDOC_LOCK_PATH="$path"
    export DEVAGENT_DEVDOC_LOCK_TOKEN="$tok"
    return 0
}

# devdoc_lock_release — release a lock THIS process acquired: only when
# DEVDOC_LOCK_OWNED=1 and the record's token is ours. Idempotent; never
# fails (safe as the first command of an EXIT trap).
devdoc_lock_release() {
    if [ "${DEVDOC_LOCK_OWNED:-0}" = 1 ] && [ -n "${DEVDOC_LOCK_PATH:-}" ] \
        && [ -n "${DEVAGENT_DEVDOC_LOCK_TOKEN:-}" ] \
        && [ "$(_devdoc_lock_field "$DEVDOC_LOCK_PATH" token)" = "$DEVAGENT_DEVDOC_LOCK_TOKEN" ]; then
        rm -f "$DEVDOC_LOCK_PATH/holder" 2>/dev/null || true
        rmdir "$DEVDOC_LOCK_PATH" 2>/dev/null || true
        unset DEVAGENT_DEVDOC_LOCK_TOKEN
        DEVDOC_LOCK_OWNED=0
    fi
    return 0
}

# devdoc_mid_merge <dir> — rc 0 when the repository holding <dir> is mid-merge
# (MERGE_HEAD present): a pathspec commit is refused there (exit 128), and a
# plain commit would conclude someone else's merge.
devdoc_mid_merge() {
    devdoc_git_ro -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1
}

# devdoc_mid_operation <dir> — rc 0 when the repository holding <dir> is mid-merge,
# mid-rebase (rebase-merge/ or rebase-apply/), mid-cherry-pick or mid-revert, with
# DEVDOC_MID_OP = merge | rebase | cherry-pick | revert; rc 1 otherwise (#1148).
# shellcheck disable=SC2034  # DEVDOC_MID_OP is the return channel — read by _devdoc_sync_state
devdoc_mid_operation() {
    local d out=""
    DEVDOC_MID_OP=""
    if devdoc_mid_merge "$1"; then DEVDOC_MID_OP=merge; return 0; fi
    out="$(devdoc_git_ro -C "$1" rev-parse --path-format=absolute --git-path rebase-merge --git-path rebase-apply 2>/dev/null)" || out=""
    while IFS= read -r d; do
        if [ -n "$d" ] && [ -e "$d" ]; then DEVDOC_MID_OP=rebase; return 0; fi
    done <<< "$out"
    if devdoc_git_ro -C "$1" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
        DEVDOC_MID_OP=cherry-pick; return 0
    fi
    if devdoc_git_ro -C "$1" rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1; then
        DEVDOC_MID_OP=revert; return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# #1055: the best-effort commit of ONE devDoc folder — filing commits
# Captures/<slug>/, ship commits the issue folder. This is a POLICY layer over
# cleanup's steps (in-git check, the lock, the mid-operation check, a porcelain
# probe, a pathspec add and commit): no commit options, no retry, never a die.
# #1056 owns the shared add/commit primitive (and its index.lock retry); when
# it lands, the probe/add/commit lines below move onto it — this is the one
# site to move.
# ---------------------------------------------------------------------------

# _devdoc_commit_warn <dir> <subject> <reason> <remedy kind> — the ONE warning
# line: `devdoc commit of <dir> skipped - <reason>; <remedy>`. Kinds: hand (the
# hand command), op:<op> (finish or abort it first), detached, repo (no git
# command: `-C <dir>` would run in the wrong repository).
_devdoc_commit_warn() {
    local dir="$1" subject="$2" reason="$3" kind="$4" cmd remedy
    cmd="git -C ${dir@Q} add -A -- . && git -C ${dir@Q} commit -m ${subject@Q} -- ."
    case "$kind" in
        op:*)     remedy="finish or abort the ${kind#op:}, then: $cmd" ;;
        detached) remedy="check out a branch, then: $cmd" ;;
        repo)     remedy="commit it from the devDoc repository by hand" ;;
        *)        remedy="commit it by hand: $cmd" ;;
    esac
    warn "devdoc commit of $dir skipped - $reason; $remedy"
}

# devdoc_commit_dir <devdoc_dir> <dir> <holder issue|-> <subject> — BEST EFFORT:
# commit <dir> alone (a `:(top,literal)` pathspec add and commit) in the
# repository holding <devdoc_dir>, under the devDoc lock, as devagent with no
# sign-off. rc 0: committed, nothing to commit, or devDoc outside git (silent,
# no lock). rc 1: not committed, exactly one warning printed. Never dies,
# never prints to stdout, never pushes, never removes a lock it did not take.
# Callers run it as `devdoc_commit_dir … || true` (errexit is then off inside,
# so every git status is tested explicitly).
devdoc_commit_dir() {
    local devdoc_dir="$1" dir="$2" holder="${3:--}" subject="$4" rc=0 top="" rel=""
    devdoc_in_git "$devdoc_dir" >/dev/null || rc=$?
    case "$rc" in
        0) ;;
        1) return 0 ;;
        *) _devdoc_commit_warn "$dir" "$subject" \
               "cannot determine the devdoc repository: a .git entry exists but git rev-parse failed" repo
           return 1 ;;
    esac
    if ! top="$(devdoc_repo_top "$devdoc_dir")" || ! rel="$(_devdoc_rel "$top" "$dir")" || [ "$rel" = . ]; then
        _devdoc_commit_warn "$dir" "$subject" "not inside the git repository holding $devdoc_dir" repo
        return 1
    fi
    (
        spec=":(top,literal)$rel"
        trap devdoc_lock_release EXIT
        _skip() { _devdoc_commit_warn "$dir" "$subject" "$1" "$2"; exit 1; }
        # A step's best-effort tail waits briefly (an explicit env value wins;
        # a run's shared deadline still caps it inside devdoc_lock_acquire).
        lrc=0
        DEVAGENT_DEVDOC_LOCK_TIMEOUT="${DEVAGENT_DEVDOC_LOCK_TIMEOUT:-10}" \
            devdoc_lock_acquire "$devdoc_dir" "$holder" "the commit command in the warning below" || lrc=$?
        case "$lrc" in
            0) ;;
            1) _skip "devdoc lock timeout" hand ;;
            *) _skip "devdoc lock location cannot be determined" hand ;;
        esac
        ! devdoc_mid_operation "$top" || _skip "devdoc repository mid-$DEVDOC_MID_OP" "op:$DEVDOC_MID_OP"
        devdoc_git_ro -C "$top" symbolic-ref -q HEAD >/dev/null 2>&1 || _skip "devdoc repository HEAD is detached" detached
        st="$(devdoc_git_ro -C "$top" status --porcelain -- "$spec")" || _skip "git status failed" hand
        [ -n "$st" ] || exit 0
        "$DEVAGENT_GIT" -C "$top" add -A -- "$spec" >&2 || _skip "git add failed" hand
        "$DEVAGENT_GIT" -C "$top" -c user.email=devagent@local -c user.name=devagent \
            commit -q -m "$subject" -- "$spec" >&2 || _skip "git commit failed" hand
        exit 0
    )
}

# ---------------------------------------------------------------------------
# #1148: the devDoc sync with origin (cleanup step 24; spec §3.3). Once per close
# it brings origin's branch of the local branch's name in and pushes, without
# rewriting a commit or losing a local change, and never touching the network
# under the devDoc lock:
#   1. unlocked: the state checks, then the ask and the fetch (upstream_branch_tip,
#      bounded by what is left of the budget);
#   2. one short hold of the devDoc lock: a re-check, the HEAD read, a diverged
#      branch merged with merge-tree + commit-tree, and the move (merge --ff-only);
#   3. unlocked: the push.
# Every function here is a SETTER-GLOBAL: call it bare, never as $(...) (register
# Issue-282). devdoc_sync never dies or exits: cleanup's outcome does not change.
# ---------------------------------------------------------------------------

# devdoc_sync_repo <dir> — rc 0 when <dir> is in a git repository that has an
# `origin`; DEVDOC_SYNC_TOP is that repository's canonical toplevel (empty outside
# git). THE scope predicate of the sync and of status's not-pushed line.
devdoc_sync_repo() {
    local t
    DEVDOC_SYNC_TOP=""
    t="$(devdoc_repo_top "$1")" || return 1
    DEVDOC_SYNC_TOP="$t"
    upstream_remote_configured "$t" origin
}

# devdoc_unpushed_text <top> <branch> — DEVDOC_UNPUSHED_TEXT from local refs only:
#   rc 0  "<N> commits not on origin/<b>, oldest <author date>"
#   rc 0  "branch <b> is not on origin"                 (no tracking ref)
#   rc 1  "0 commits not on origin/<b>"
#   rc 2  "commits not on origin/<b> could not be counted"
# The date is the oldest commit's author date in its own zone (%Y-%m-%d %H:%M %z).
devdoc_unpushed_text() {
    local top="$1" b="$2" n=0 out="" rc=0 at ad min="" oldest=""
    DEVDOC_UNPUSHED_TEXT=""
    if ! "$DEVAGENT_GIT" -C "$top" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" >/dev/null 2>&1; then
        DEVDOC_UNPUSHED_TEXT="branch $b is not on origin"
        return 0
    fi
    # One walk: the count is the number of commits the log prints.
    out="$("$DEVAGENT_GIT" -C "$top" log --format='%at %ad' --date=format:'%Y-%m-%d %H:%M %z' \
        "refs/remotes/origin/$b..refs/heads/$b" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        DEVDOC_UNPUSHED_TEXT="commits not on origin/$b could not be counted"
        return 2
    fi
    while read -r at ad; do
        [[ "$at" =~ ^[0-9]+$ ]] || continue
        n=$((n + 1))
        if [ -z "$min" ] || [ "$at" -lt "$min" ]; then min="$at"; oldest="$ad"; fi
    done <<< "$out"
    if [ "$n" -eq 0 ]; then
        DEVDOC_UNPUSHED_TEXT="0 commits not on origin/$b"
        return 1
    fi
    DEVDOC_UNPUSHED_TEXT="$n commits not on origin/$b, oldest $oldest"
}

# _devdoc_sync_state <top> — read the branch into _DS_BRANCH (refs/heads/ stripped by
# hand, never --short: a tag named like the branch makes --short say heads/<b>; empty
# when detached; _DS_DETACHED=1 then). rc 1 after a refusal (_ds_set) when the
# repository cannot sync: mid-operation first, then detached, then git-failed. So a
# mid-merge on a branch keeps its branch in the line, and a stopped rebase shows
# (detached HEAD).
_devdoc_sync_state() {
    local top="$1" ref="" rc=0
    _DS_BRANCH=""; _DS_DETACHED=0
    ref="$("$DEVAGENT_GIT" -C "$top" symbolic-ref -q HEAD 2>/dev/null)" || rc=$?
    case "$rc:$ref" in
        0:refs/heads/?*) _DS_BRANCH="${ref#refs/heads/}" ;;
        1:*) _DS_DETACHED=1 ;;
    esac
    if devdoc_mid_operation "$top"; then
        _ds_set refused "mid-$DEVDOC_MID_OP" "the repository is mid-$DEVDOC_MID_OP" \
            "Finish the $DEVDOC_MID_OP by hand, or let the session that started it finish; the next close retries."
        return 1
    elif [ "$rc" -eq 1 ]; then
        _ds_set refused detached "HEAD is detached" "Check out the devDoc branch; the next close retries."
        return 1
    elif [ -z "$_DS_BRANCH" ]; then
        _ds_set refused git-failed "git symbolic-ref exited $rc"
        return 1
    fi
    return 0
}

# _devdoc_sync_track <top> <branch> <sha> — move refs/remotes/origin/<branch> FORWARD
# to <sha> (what origin is now known to hold): only when it is absent or an ancestor
# of <sha>, compare-and-swap against the value read. A failed swap is ignored (a
# concurrent fetch wrote a newer value). Never a network call.
_devdoc_sync_track() {
    local top="$1" b="$2" sha="$3" cur=""
    cur="$("$DEVAGENT_GIT" -C "$top" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)" || cur=""
    [ "$cur" != "$sha" ] || return 0
    if [ -z "$cur" ] || "$DEVAGENT_GIT" -C "$top" merge-base --is-ancestor "$cur" "$sha" 2>/dev/null; then
        "$DEVAGENT_GIT" -C "$top" update-ref "refs/remotes/origin/$b" "$sha" "$cur" 2>/dev/null || true
    fi
    return 0
}

# _ds_set <outcome> <token> <reason> [<next>] — record why the sync warns (each call
# replaces the last). <next> defaults to "The next close retries."
_ds_set() {
    DEVDOC_SYNC_OUTCOME="$1"; DEVDOC_SYNC_REASON="$2"; _DS_WHY="$3"; _DS_NEXT="${4:-The next close retries.}"
}

# _ds_git_failed <sub> <rc> [<stderr file>] — the git-failed reason: `git <sub>
# exited <rc>`, plus the first fatal:/error: line of <stderr file>, else its first
# line not starting `To `.
_ds_git_failed() {
    local detail="" line first=""
    if [ -n "${3:-}" ] && [ -s "$3" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in
                fatal:*|error:*) detail="$line"; break ;;
                "To "*|"") ;;
                *) [ -n "$first" ] || first="$line" ;;
            esac
        done < "$3"
        [ -n "$detail" ] || detail="$first"
    fi
    _ds_cap "$detail"
    _ds_set refused git-failed "git $1 exited $2${_DS_CAPPED:+: $_DS_CAPPED}"
}

# _ds_cap <text> — _DS_CAPPED is <text> cut to 240 characters (each field of the
# WARNING line is capped, not the whole line).
_ds_cap() {
    _DS_CAPPED="$1"
    [ "${#_DS_CAPPED}" -le 240 ] || _DS_CAPPED="${_DS_CAPPED:0:237}..."
}

# _devdoc_sync_hold <top> — the locked part: the re-check, the HEAD read, the
# classification, the merge commit and the move. Reads DEVDOC_SYNC_BRANCH _DS_TIP
# _DS_NEW; sets _DS_KIND (new|same|ahead|behind|diverged) and _DS_S (the SHA to push).
# rc 1 after a refusal (_ds_set).
_devdoc_sync_hold() {
    local top="$1" b="$DEVDOC_SYNC_BRANCH" T="$_DS_TIP" H="" ilock="" rc=0 base="" M="" X=""
    _DS_KIND=""; _DS_S=""
    _devdoc_sync_state "$top" || return 1
    if [ "$_DS_BRANCH" != "$b" ]; then
        _ds_set refused head-moved "HEAD moved while the sync ran"
        return 1
    fi
    ilock="$("$DEVAGENT_GIT" -C "$top" rev-parse --path-format=absolute --git-path index.lock 2>"$_DS_ERR")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$ilock" ]; then _ds_git_failed rev-parse "$rc" "$_DS_ERR"; return 1; fi
    if [ -e "$ilock" ]; then
        _ds_set refused index-lock "another git process holds $ilock"
        return 1
    fi
    H="$("$DEVAGENT_GIT" -C "$top" rev-parse -q --verify 'HEAD^{commit}' 2>"$_DS_ERR")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$H" ]; then _ds_git_failed rev-parse "$rc" "$_DS_ERR"; return 1; fi
    if [ "$_DS_NEW" = 1 ]; then _DS_KIND=new; _DS_S="$H"; return 0; fi
    if [ "$H" = "$T" ]; then _DS_KIND=same; return 0; fi
    # One walk classifies: when one side contains the other, it is the merge base.
    rc=0; base="$("$DEVAGENT_GIT" -C "$top" merge-base "$H" "$T" 2>/dev/null)" || rc=$?
    case "$rc:$base" in
        0:"$T") _DS_KIND=ahead; _DS_S="$H"; return 0 ;;
        0:"$H") _DS_KIND=behind; X="$T" ;;
        0:?*) _DS_KIND=diverged ;;
        1:*) _ds_set refused unrelated "$b and origin/$b share no history" \
                 "Reconcile the two histories by hand; the next close retries."
             return 1 ;;
        *) _ds_git_failed merge-base "$rc"; return 1 ;;
    esac
    if [ "$_DS_KIND" = diverged ]; then
        rc=0; merge_forward_merge "$top" "$H" "$T" || rc=$?
        case "$rc" in
            0) ;;
            2) _ds_set refused git-failed "git merge-tree exited $MF_MERGE_RC"
               return 1 ;;
            *) if [ "${#MF_CONFLICTED[@]}" -gt 0 ]; then _ds_paths "${MF_CONFLICTED[@]}"; else _DS_PATHS="(paths not named)"; fi
               _ds_set refused conflict "merging origin/$b conflicts in $_DS_PATHS" \
                   "Merge origin/$b into $b by hand in $top; the next close pushes the result."
               return 1 ;;
        esac
        rc=0
        M="$(GIT_AUTHOR_NAME=devagent GIT_AUTHOR_EMAIL=devagent@local \
            GIT_COMMITTER_NAME=devagent GIT_COMMITTER_EMAIL=devagent@local \
            "$DEVAGENT_GIT" -C "$top" commit-tree "$MF_MTREE" -p "$H" -p "$T" \
            -m "devdoc: merge origin/$b into $b ($_DS_SUBJ)" 2>"$_DS_ERR")" || rc=$?
        if [ "$rc" -ne 0 ] || [ -z "$M" ]; then _ds_git_failed commit-tree "$rc" "$_DS_ERR"; return 1; fi
        X="$M"; _DS_S="$M"
    fi
    _devdoc_sync_move "$top" "$H" "$X"
}

# _devdoc_sync_move <top> <H> <X> — fast-forward the branch, index and tree from <H>
# to <X> under the lock: --ff-only (the branch moves only from the HEAD the sync
# read), --no-autostash and --no-overwrite-ignore (nothing local is lost, whatever
# the config), LC_ALL=C (the stderr parsed below is git's English). rc 1 after a
# refusal.
_devdoc_sync_move() {
    local top="$1" H="$2" X="$3" rc=0 p st line hdr="" ref="" h="" ilock="" why=""
    local -a D=() gone=() left=()
    local -A xdel=() del=() existed=() w0=() nx=()
    _DS_EDITED=(); _DS_UNTRACKED=()
    # The paths the move would touch (xdel: the ones origin deletes).
    "$DEVAGENT_GIT" -C "$top" diff --no-renames --name-status -z "$H" "$X" >"$_DS_LIST" 2>"$_DS_ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then _ds_git_failed diff "$rc" "$_DS_ERR"; return 1; fi
    while IFS= read -r -d '' st && IFS= read -r -d '' p; do
        D+=("$p"); [ "$st" != D ] || xdel[$p]=1
    done <"$_DS_LIST"
    # One scan gives both: every entry is W0 (tracked files that already differ from
    # the index), and the D entries are the deleted ones.
    devdoc_git_ro -C "$top" diff --no-renames --name-status -z >"$_DS_LIST" 2>"$_DS_ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then _ds_git_failed diff "$rc" "$_DS_ERR"; return 1; fi
    while IFS= read -r -d '' st && IFS= read -r -d '' p; do
        w0[$p]=1; [ "$st" != D ] || del[$p]=1
    done <"$_DS_LIST"
    # Pre-move refusal (operator ruling): an unstaged deletion of a file origin
    # changed is a file in the way (git would re-create it); refuse, change nothing.
    # One origin deleted as well is not in the way: the move loses nothing there.
    for p in "${D[@]}"; do
        [ -z "${del[$p]+x}" ] || [ -n "${xdel[$p]+x}" ] || gone+=("$p")
    done
    if [ "${#gone[@]}" -gt 0 ]; then
        _DS_EDITED=("${gone[@]}")
        _ds_in_the_way
        return 1
    fi
    # The rest of the snapshot the rule-4 undo works from: which of the paths exist,
    # and which differ in the index from <X> (nx; the others are skip paths, whose
    # index already equals origin's, so git moves past them).
    for p in "${D[@]}"; do
        if [ -e "$top/$p" ] || [ -L "$top/$p" ]; then existed[$p]=1; fi
    done
    "$DEVAGENT_GIT" -C "$top" diff --cached --no-renames --name-only -z "$X" >"$_DS_LIST" 2>"$_DS_ERR" || rc=$?
    if [ "$rc" -ne 0 ]; then _ds_git_failed diff "$rc" "$_DS_ERR"; return 1; fi
    while IFS= read -r -d '' p; do nx[$p]=1; done <"$_DS_LIST"
    LC_ALL=C "$DEVAGENT_GIT" -C "$top" merge --ff-only --no-autostash --no-overwrite-ignore "$X" \
        </dev/null >/dev/null 2>"$_DS_ERR" || rc=$?
    if [ "$rc" -eq 0 ]; then
        # The move finished, but a file origin deleted could not be deleted here
        # (git exits 0 then, U9): the outcome stands and the warning names it.
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            if [[ "$line" =~ unable\ to\ unlink\ \'([^\']+)\'\:\ (.+)$ ]]; then
                left+=("${BASH_REMATCH[1]}"); [ -n "$why" ] || why="${BASH_REMATCH[2]}"
            fi
        done <"$_DS_ERR"
        if [ "${#left[@]}" -gt 0 ]; then
            _ds_paths "${left[@]}"
            _DS_LEFT_WHY="the move could not delete $_DS_PATHS, which origin deleted ($why); it is now an untracked copy of the version in ${H:0:7}"
            _DS_LEFT_NEXT="Once access is fixed, delete it (its content is in ${H:0:7}, so nothing is lost); a later commit could otherwise add it back."
        fi
        return 0
    fi
    # A failed move, classified in this order. 1: HEAD or the branch changed (decided
    # by state, never by git's wording).
    ref="$("$DEVAGENT_GIT" -C "$top" symbolic-ref -q HEAD 2>/dev/null)" || ref=""
    h="$("$DEVAGENT_GIT" -C "$top" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || h=""
    if [ "$ref" != "refs/heads/$DEVDOC_SYNC_BRANCH" ] || [ "$h" != "$H" ]; then
        _ds_set refused head-moved "HEAD moved while the sync ran"
        return 1
    fi
    # 2: git's pre-check named files in the way; 3: another git process holds the
    # index lock. stderr is git's English (LC_ALL=C), read line by line.
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            *"would be overwritten by merge:"|*"would be removed by merge:"|*"would lose untracked files in them:")
                case "$line" in *"Your local changes"*) hdr=edited ;; *) hdr=untracked ;; esac ;;
            $'\t'?*)
                case "$hdr" in
                    edited) _DS_EDITED+=("${line#$'\t'}") ;;
                    untracked) _DS_UNTRACKED+=("${line#$'\t'}") ;;
                esac ;;
            *) hdr=""
               if [[ "$line" =~ \'([^\']*index\.lock)\'\:\ File\ exists ]]; then ilock="${BASH_REMATCH[1]}"; fi ;;
        esac
    done <"$_DS_ERR"
    if [ "${#_DS_EDITED[@]}" -gt 0 ] || [ "${#_DS_UNTRACKED[@]}" -gt 0 ]; then
        _ds_in_the_way
        return 1
    fi
    if [ -n "$ilock" ]; then
        _ds_set refused index-lock "another git process holds $ilock"
        return 1
    fi
    # 4: anything else with HEAD unmoved: undo whatever the move wrote (rule 4).
    _devdoc_sync_undo "$top" "$H" "$rc"
    return 1
}

# _devdoc_sync_undo <top> <H> <merge rc> — rule 4: a move that failed with HEAD
# unmoved has written origin's version of some paths, deleted some and created some.
# Two shapes: it stopped part-way in the tree (on Windows, a file another program
# holds open), with the index unmoved; or it failed at its last step, the ref update
# (another process holds refs/heads/<b>.lock), with the index and tree already moved.
# So the index entries of every non-skip path go back to <H> first (a no-op in the
# first shape: before the move they equalled <H>, or git would have refused), then
# the tree is put back from the index. Called by _devdoc_sync_move, whose D, existed,
# w0 and nx it reads (bash's dynamic scope). Never keyed on one phrase. Paths git
# named are named in the warning but NOT exempt: git may have unlinked one before it
# failed to create its replacement, and a held file it never touched does not differ
# from the index, so it is not restored. Skip paths (rule 3 keeps a further edit) are
# left alone. Lossless: after the pre-move refusal W0 ∩ D holds only skip paths and
# paths both sides deleted, so every restored path matched the index before the move.
_devdoc_sync_undo() {
    local top="$1" H="$2" mrc="$3" p line r=0 detail=""
    local -a named=() back=() restore=() removed=() bad=() pairs=()
    local -A why=() w1=() w2=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ unable\ to\ unlink\ (old\ )?\'([^\']+)\'\:\ (.+)$ ]]; then
            p="${BASH_REMATCH[2]}"; line="${BASH_REMATCH[3]}"
        elif [[ "$line" =~ unable\ to\ create\ file\ ([^:]+)\:\ (.+)$ ]]; then
            p="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"
        else
            continue
        fi
        [ -n "${why[$p]+x}" ] || { why[$p]="$line"; named+=("$p"); }
    done <"$_DS_ERR"
    _ds_git_failed merge "$mrc" "$_DS_ERR"; detail="$_DS_WHY"     # kept for the no-change case
    for p in "${D[@]}"; do [ -z "${nx[$p]+x}" ] || back+=("$p"); done
    if [ "${#back[@]}" -gt 0 ]; then
        printf '%s\0' "${back[@]}" >"$_DS_LIST"
        GIT_LITERAL_PATHSPECS=1 "$DEVAGENT_GIT" -C "$top" reset -q "$H" --pathspec-from-file=- --pathspec-file-nul \
            <"$_DS_LIST" >/dev/null 2>&1 || r=$?
    fi
    if [ "$r" -eq 0 ]; then
        devdoc_git_ro -C "$top" diff --no-renames --name-only -z >"$_DS_LIST" 2>/dev/null || r=$?
        while IFS= read -r -d '' p; do w1[$p]=1; done <"$_DS_LIST"
    fi
    for p in "${D[@]}"; do
        [ -n "${nx[$p]+x}" ] || continue                             # skip: index = target before the move
        if [ "$r" -ne 0 ]; then bad+=("$p"); continue; fi            # cannot tell what changed
        if [ -n "${w1[$p]+x}" ] && [ -z "${w0[$p]+x}" ]; then restore+=("$p"); fi
        if [ -z "${existed[$p]+x}" ] && { [ -e "$top/$p" ] || [ -L "$top/$p" ]; }; then
            rm -f -- "$top/$p" 2>/dev/null || true
            removed+=("$p")
        fi
    done
    if [ "${#restore[@]}" -gt 0 ]; then
        printf '%s\0' "${restore[@]}" >"$_DS_LIST"
        GIT_LITERAL_PATHSPECS=1 "$DEVAGENT_GIT" -C "$top" checkout --pathspec-from-file=- --pathspec-file-nul \
            <"$_DS_LIST" >/dev/null 2>&1 || true
        r=0; devdoc_git_ro -C "$top" diff --no-renames --name-only -z >"$_DS_LIST" 2>/dev/null || r=$?
        while IFS= read -r -d '' p; do w2[$p]=1; done <"$_DS_LIST"
        for p in "${restore[@]}"; do
            if [ "$r" -ne 0 ] || [ -n "${w2[$p]+x}" ]; then bad+=("$p"); fi
        done
    fi
    for p in "${removed[@]}"; do
        if [ -e "$top/$p" ] || [ -L "$top/$p" ]; then bad+=("$p"); fi
    done
    if [ "${#named[@]}" -eq 0 ] && [ "${#restore[@]}" -eq 0 ] && [ "${#removed[@]}" -eq 0 ] && [ "${#bad[@]}" -eq 0 ]; then
        return 0                                                     # nothing changed: git-failed stands
    fi
    if [ "${#named[@]}" -gt 0 ]; then
        for p in "${named[@]}"; do pairs+=("$p: ${why[$p]}"); done
        _ds_paths "${pairs[@]}"
        line="the move stopped part-way at $_DS_PATHS; "
    else
        line="the move stopped part-way (${detail}); "
    fi
    if [ "${#bad[@]}" -eq 0 ]; then
        line="${line}the move was undone"
    else
        _ds_paths "${bad[@]}"
        line="${line}$_DS_PATHS could not be restored and hold origin's content, not a local edit"
    fi
    if [ "${#named[@]}" -gt 0 ]; then
        _ds_paths "${named[@]}"
        _ds_set refused part-way "$line" \
            "Free or fix access to $_DS_PATHS (on Windows another program may hold it open); the next close retries."
    else
        _ds_set refused part-way "$line"
    fi
}

# _ds_in_the_way — the in-the-way refusal from _DS_EDITED (edited or deleted tracked
# files) and _DS_UNTRACKED (untracked or ignored files). The remedy never says
# discard and never implies add -f (operator rulings).
_ds_in_the_way() {
    local next="" reason
    _ds_paths "${_DS_EDITED[@]}" "${_DS_UNTRACKED[@]}"
    reason="uncommitted files are in the way of origin's changes: $_DS_PATHS"
    if [ "${#_DS_EDITED[@]}" -gt 0 ]; then
        _ds_paths "${_DS_EDITED[@]}"
        next="Commit the edits to $_DS_PATHS, or let the session that owns them close."
    fi
    if [ "${#_DS_UNTRACKED[@]}" -gt 0 ]; then
        _ds_paths "${_DS_UNTRACKED[@]}"
        next="${next:+$next }Move $_DS_PATHS aside (origin now tracks them), or let the session that owns them close."
    fi
    _ds_set refused in-the-way "$reason" "$next The next close retries."
}

# _ds_paths <path>… — _DS_PATHS lists at most 5 of them, then (+N more).
_ds_paths() {
    local n="$#" s
    printf -v s '%s, ' "${@:1:5}"; s="${s%, }"
    [ "$n" -le 5 ] || s="$s (+$((n - 5)) more)"
    _ds_cap "$s"; _DS_PATHS="$_DS_CAPPED"
}

# devdoc_sync <devdoc_dir> <issue|-> <budget_secs> [<mode>] — sync the repository
# holding <devdoc_dir> with origin's branch of the local branch's name. rc 0: nothing
# to warn about; rc 1: DEVDOC_SYNC_LINE is the one line to print. Never anything else.
#   <mode>  absent or empty = push (cleanup, step 24). no-push (#1149, step 21's wbs
#           update): the same fetch and locked move, one attempt at the lock
#           (DEVAGENT_DEVDOC_LOCK_TIMEOUT=0 for that acquire only), and no push. Any
#           other value refuses (bad-mode) before every check and every git call.
#   DEVDOC_SYNC_OUTCOME  off | same | pushed | fast-forwarded | merged | refused | skipped
#                        no-push adds ahead (nothing to bring in); there fast-forwarded
#                        and merged are local only, and pushed is never set
#   DEVDOC_SYNC_REASON   the warning's token (conflict, in-the-way, budget, …), or empty
#   DEVDOC_SYNC_REPO     the repository's toplevel; DEVDOC_SYNC_BRANCH its branch
#   DEVDOC_SYNC_LINE     devDoc sync <refused|skipped|finished> for <repo> (<branch>): <reason>. <count>. <next>
#                        no-push: no count, and the step-21 tail (see _devdoc_sync_line)
# <budget_secs> bounds the sum of the network calls; the lock wait spends none of it.
# A trust check on the devDoc's origin (#958) belongs here, inside devdoc_sync, so
# that it covers both callers.
# shellcheck disable=SC2034  # the DEVDOC_SYNC_* globals are the return channel — read by cleanup.sh
devdoc_sync() {
    DEVDOC_SYNC_OUTCOME=off; DEVDOC_SYNC_REASON=""; DEVDOC_SYNC_REPO=""; DEVDOC_SYNC_BRANCH=""; DEVDOC_SYNC_LINE=""
    _DS_WHY=""; _DS_NEXT=""; _DS_ALSO=""; _DS_TMPD=""; _DS_ERR=/dev/null; _DS_LIST=/dev/null; _DS_DETACHED=0; _DS_BRANCH=""
    _DS_ISSUE="$2"; _DS_BUDGET="$3"; _DS_MODE="${4:-push}"; _DS_SUBJ="$_DS_ISSUE cleanup"
    _DS_LEFT_WHY=""; _DS_LEFT_NEXT=""; _DS_KIND=""; _DS_LOCK_WAIT="${DEVAGENT_DEVDOC_LOCK_TIMEOUT:-}"
    case "$_DS_MODE" in
        push) ;;
        no-push)
            _DS_LOCK_WAIT=0
            case "$_DS_ISSUE" in ""|-) _DS_SUBJ="wbs update" ;; *) _DS_SUBJ="$_DS_ISSUE wbs update" ;; esac ;;
        *) _ds_set skipped bad-mode "unknown sync mode '$_DS_MODE'"; _DS_MODE=push ;;
    esac
    [ -n "$DEVDOC_SYNC_REASON" ] || _devdoc_sync_body "$1" || true
    if [ -n "$_DS_LEFT_WHY" ]; then                                  # a held deleted file (Task 5)
        if [ -z "$DEVDOC_SYNC_REASON" ]; then
            DEVDOC_SYNC_REASON=leftover; _DS_WHY="$_DS_LEFT_WHY"; _DS_NEXT="$_DS_LEFT_NEXT"
        else
            _DS_ALSO="$_DS_LEFT_WHY. $_DS_LEFT_NEXT"
        fi
    fi
    [ -z "$_DS_TMPD" ] || rm -rf "$_DS_TMPD" 2>/dev/null || true
    [ -n "$DEVDOC_SYNC_REASON" ] || return 0
    _devdoc_sync_line
    return 1
}

# _devdoc_sync_body <devdoc_dir> — devdoc_sync's steps; the issue and the budget are
# _DS_ISSUE and _DS_BUDGET.
_devdoc_sync_body() {
    local devdoc_dir="$1" top b dl t0 rc=0 lrc=0 hrc=0 prc=0 frc=0 pre="" cur=""
    devdoc_sync_repo "$devdoc_dir" || return 0
    top="$DEVDOC_SYNC_TOP"; DEVDOC_SYNC_REPO="$top"
    rc=0; _devdoc_sync_state "$top" || rc=$?
    b="$_DS_BRANCH"; DEVDOC_SYNC_BRANCH="$b"
    [ "$rc" -eq 0 ] || return 0
    if ! command -v timeout >/dev/null 2>&1; then
        _ds_set skipped no-timeout "timeout(1) is not on PATH, so the network calls cannot be bounded" \
            "Put coreutils' timeout on PATH; the next close retries."
        return 0
    fi
    # 1. The ask and the fetch, unlocked.
    pre="$("$DEVAGENT_GIT" -C "$top" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)" || pre=""
    bounded_now_us; dl=$((BOUNDED_NOW_US + _DS_BUDGET * 1000000))
    upstream_branch_tip "$top" "$b" "$_DS_BUDGET" "$dl" || true
    _DS_TMPD="$(mktemp -d 2>/dev/null)" || _DS_TMPD=""
    if [ -z "$_DS_TMPD" ] || [ ! -d "$_DS_TMPD" ]; then
        _DS_TMPD=""
        _ds_set skipped no-tmp "a temporary directory could not be created" "Skipped for this close; the next close retries."
        return 0
    fi
    _DS_ERR="$_DS_TMPD/err"; _DS_LIST="$_DS_TMPD/list"
    _DS_TIP=""; _DS_NEW=0
    case "$UPSTREAM_TIP" in
        "(unreachable)")
            case "$UPSTREAM_ASK_RC" in
                124|137) _ds_budget ;;
                *) _ds_set refused fetch-failed "the fetch failed ($UPSTREAM_TIP_WHY)" ;;
            esac
            return 0 ;;
        "(unpushed)") _DS_NEW=1 ;;
        *)
            _DS_TIP="$UPSTREAM_TIP"
            case "$UPSTREAM_FETCH_RC" in
                ""|0) ;;
                budget|124|137) _ds_budget; return 0 ;;
                *)  # Another session's fetch may have moved origin/<b> at the same moment
                    # ("cannot lock ref"): done when the ref moved and the tip is here;
                    # otherwise one retry, within the budget.
                    cur="$("$DEVAGENT_GIT" -C "$top" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)" || cur=""
                    if [ "$cur" = "$pre" ] || ! "$DEVAGENT_GIT" -C "$top" cat-file -e "$_DS_TIP^{commit}" 2>/dev/null; then
                        if ! bounded_secs_left "$dl" "$_DS_BUDGET"; then _ds_budget; return 0; fi
                        _upstream_fetch_branch "$top" "$BOUNDED_SECS" "$b" || frc=$?
                        case "$frc" in
                            0) ;;
                            124|137) _ds_budget; return 0 ;;
                            *) _ds_set refused fetch-failed "the fetch failed (git fetch exited $frc)"
                               return 0 ;;
                        esac
                    fi ;;
            esac
            if ! "$DEVAGENT_GIT" -C "$top" cat-file -e "$_DS_TIP^{commit}" 2>/dev/null; then
                _ds_set refused fetch-failed "the fetch failed (origin's $b tip $_DS_TIP is not here after it)"
                return 0
            fi
            [ -n "$UPSTREAM_FETCH_RC" ] || _devdoc_sync_track "$top" "$b" "$_DS_TIP" ;;
    esac
    # 2. One short hold: no network call under the lock; the wait spends no budget.
    bounded_now_us; t0="$BOUNDED_NOW_US"
    DEVAGENT_DEVDOC_LOCK_TIMEOUT="$_DS_LOCK_WAIT" \
        devdoc_lock_acquire "$devdoc_dir" "$_DS_ISSUE" "the next close" 2>/dev/null || lrc=$?   # no-push: one attempt (#1149)
    case "$lrc" in
        0) ;;
        1) _ds_set skipped lock-busy "the devDoc lock is busy" "Skipped for this close; the next close retries."; return 0 ;;
        *) _ds_set skipped lock-location "the devDoc lock location cannot be determined" "Skipped for this close; the next close retries."; return 0 ;;
    esac
    _devdoc_sync_hold "$top" || hrc=$?
    devdoc_lock_release
    bounded_now_us; dl=$((dl + BOUNDED_NOW_US - t0))
    [ "$hrc" -eq 0 ] || return 0
    case "$_DS_KIND" in
        same) DEVDOC_SYNC_OUTCOME=same; return 0 ;;
        behind) DEVDOC_SYNC_OUTCOME=fast-forwarded; return 0 ;;
    esac
    if [ "$_DS_MODE" = no-push ]; then                               # step 21 never pushes (#1149)
        case "$_DS_KIND" in
            diverged) DEVDOC_SYNC_OUTCOME=merged ;;
            *) DEVDOC_SYNC_OUTCOME=ahead ;;
        esac
        return 0
    fi
    # 3. The push, unlocked, bounded by what is left of the budget.
    if ! bounded_secs_left "$dl" "$_DS_BUDGET"; then _ds_budget; return 0; fi
    LC_ALL=C GIT_TERMINAL_PROMPT=0 bounded_call "$BOUNDED_SECS" "$DEVAGENT_GIT" -C "$top" \
        push origin "$_DS_S:refs/heads/$b" </dev/null >/dev/null 2>"$_DS_ERR" || prc=$?
    if [ "$prc" -ne 0 ]; then
        _ds_push_failed "$prc"                                       # never retried within one close
        return 0
    fi
    _devdoc_sync_track "$top" "$b" "$_DS_S"
    case "$_DS_KIND" in
        diverged) DEVDOC_SYNC_OUTCOME=merged ;;
        *) DEVDOC_SYNC_OUTCOME=pushed ;;
    esac
    return 0
}

# _ds_push_failed <rc> — classify a failed push from git's stderr (LC_ALL=C), in
# order: the bound expired; origin moved (` ! [rejected] … (fetch first|non-fast-forward)`);
# origin moved DURING the push (another push won receive-pack's ref lock: `cannot lock
# ref … but expected …` in the reject reason or a `remote:` line); the remote refused
# it (` ! [remote rejected] `, quoting up to 3 `remote:` lines with their padding
# stripped); anything else is git-failed.
_ds_push_failed() {
    local line t rej="" rrej="" kind="" rl="" race=""
    local -a remote=()
    case "$1" in 124|137) _ds_budget; return 0 ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in *"cannot lock ref"*"but expected"*) race=1 ;; esac
        if [ -z "$rej" ] && [[ "$line" =~ ^\ !\ \[rejected\]\ .*\((fetch\ first|non-fast-forward)\)$ ]]; then
            rej="${line# }"; kind="${BASH_REMATCH[1]}"
        elif [ -z "$rrej" ] && [[ "$line" =~ ^\ !\ \[remote\ rejected\]\  ]]; then
            rrej="${line# }"
        elif [[ "$line" =~ ^remote:\ ?(.*)$ ]]; then
            t="${BASH_REMATCH[1]}"; t="${t%"${t##*[![:space:]]}"}"
            [ -z "$t" ] || [ "${#remote[@]}" -ge 3 ] || remote+=("remote: $t")
        fi
    done <"$_DS_ERR"
    if [ -n "$rej" ]; then
        _ds_cap "$rej"
        _ds_set refused origin-moved "origin/$DEVDOC_SYNC_BRANCH moved before the push ($kind): $_DS_CAPPED"
    elif [ -n "$rrej" ] && [ -n "$race" ]; then
        _ds_cap "$rrej"
        _ds_set refused origin-moved "origin/$DEVDOC_SYNC_BRANCH moved during the push (another push updated it first): $_DS_CAPPED"
    elif [ -n "$rrej" ]; then
        if [ "${#remote[@]}" -gt 0 ]; then
            printf -v rl '%s; ' "${remote[@]}"
        fi
        _ds_cap "$rl$rrej"
        _ds_set refused remote-refused "origin refused the push: $_DS_CAPPED" "Fix what the remote names; the next close retries."
    else
        _ds_git_failed push "$1" "$_DS_ERR"
    fi
}

# _ds_budget — the time budget ran out, during a call or before the next could start.
# After a diverged merge (the push is the only call left) the line says the merge
# commit is here, unpushed.
_ds_budget() {
    local reason="the time budget ran out (DEVAGENT_DEVDOC_SYNC_SECS=$_DS_BUDGET)"
    [ "$_DS_KIND" != diverged ] \
        || reason="$reason before the push; origin/$DEVDOC_SYNC_BRANCH is merged into $DEVDOC_SYNC_BRANCH here, not yet pushed"
    _ds_set skipped budget "$reason" "Skipped for this close; the next close retries."
}

# _devdoc_sync_line — DEVDOC_SYNC_LINE from the recorded reason. The count is read
# after any move; a HEAD with no branch shows as (detached HEAD), with no count.
# no-push (#1149) drops the count (cleanup reports it). A refusal or skip there keeps
# the core's remedy without its "the next close retries" clause, drops a remedy that
# only says when the close retries (and conflict's hand merge, which cleanup's warning
# gives), and ends "This step uses this machine's copy; the next cleanup syncs again."
# shellcheck disable=SC2034  # DEVDOC_SYNC_LINE is the return channel — read by cleanup.sh
_devdoc_sync_line() {
    local verb br count="" next="$_DS_NEXT"
    case "$DEVDOC_SYNC_OUTCOME" in
        skipped) verb=skipped ;;
        refused) verb=refused ;;
        *) verb=finished ;;
    esac
    if [ -n "$DEVDOC_SYNC_BRANCH" ]; then
        br="($DEVDOC_SYNC_BRANCH)"
        if [ "$_DS_MODE" != no-push ]; then
            devdoc_unpushed_text "$DEVDOC_SYNC_REPO" "$DEVDOC_SYNC_BRANCH" || true
            count=" $DEVDOC_UNPUSHED_TEXT."
        fi
    elif [ "$_DS_DETACHED" = 1 ]; then
        br="(detached HEAD)"
    else
        br="(branch unknown)"
    fi
    if [ "$_DS_MODE" = no-push ] && [ "$verb" != finished ]; then
        case "$DEVDOC_SYNC_REASON:$next" in
            conflict:*|*:"The next close retries."|*:"Skipped for this close; the next close retries.") next="" ;;
            *:*"; the next close retries.") next="${next%; the next close retries.}." ;;
            *:*" The next close retries.") next="${next% The next close retries.}" ;;
        esac
        next="${next:+$next }This step uses this machine's copy; the next cleanup syncs again."
    fi
    DEVDOC_SYNC_LINE="devDoc sync $verb for $DEVDOC_SYNC_REPO $br: ${_DS_WHY%.}.$count $next${_DS_ALSO:+ Also: $_DS_ALSO}"
    # git's and the remote's text is quoted in it: no control character survives
    # (an escape sequence or a carriage return could repaint the terminal line).
    DEVDOC_SYNC_LINE="${DEVDOC_SYNC_LINE//[[:cntrl:]]/?}"
}
