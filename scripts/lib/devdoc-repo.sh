#!/usr/bin/env bash
# scripts/lib/devdoc-repo.sh — the devDoc repository discipline (#749).
# Every devagent write into the shared devDoc repository goes through here:
# read-only git calls that never take git's optional index lock, the ONE
# definition of the paths a cleanup owns, and the mid-merge check.
# Needs io.sh (die/warn/info). Safe to source multiple times.

: "${DEVAGENT_GIT:=git}"

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

# _devdoc_rel <repo_top> <path> — <path> relative to <repo_top>, both
# canonicalised; rc 1 when <path> is outside it. <path>'s parent must exist.
_devdoc_rel() {
    local top="$1" p="$2" c
    if [ -d "$p" ]; then
        c="$(cd "$p" && pwd -P)" || return 1
    else
        c="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")" || return 1
    fi
    [ "$c" = "$top" ] && { printf '.\n'; return 0; }
    case "$c" in "$top"/*) printf '%s\n' "${c#"$top"/}" ;; *) return 1 ;; esac
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
    local prefix entry xy p skip_next=0 o orel unit u stale=() units=() n shown more msg
    local -A seen=()
    prefix="$(cd "$devdoc_dir" && devdoc_git_ro rev-parse --show-prefix 2>/dev/null)" || return 0
    while IFS= read -r -d '' entry; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi   # a rename's source path
        xy="${entry:0:2}"; p="${entry:3}"
        case "$xy" in R*|C*|?R|?C) skip_next=1 ;; esac
        p="${p#"$prefix"}"
        for o in "${DEVDOC_OWNED[@]}"; do
            orel="${o#:(top,literal)}"; orel="${orel#"$prefix"}"
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
        u="$(printf '%s, ' "${stale[@]}")"; u="${u%, }"
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
# rc 2 (no output) when the location cannot be determined.
devdoc_lock_path() {
    local c rc=0
    c="$(devdoc_in_git "$1")" || rc=$?
    case "$rc" in
        0) printf '%s/devagent-devdoc.lock\n' "$c" ;;
        1) printf '%s/.devagent-wbs.lock\n' "$(cd "$1" && pwd -P)" ;;
        *) return 2 ;;
    esac
}

# _devdoc_lock_timeout — resolve DEVAGENT_DEVDOC_LOCK_TIMEOUT (seconds,
# ^[0-9]{1,5}$, default 120, 0 = one attempt) into DEVDOC_LOCK_TIMEOUT_S; an
# invalid value warns once per process and uses the default.
_devdoc_lock_timeout() {
    local v="${DEVAGENT_DEVDOC_LOCK_TIMEOUT:-}"
    if [ -z "$v" ]; then
        DEVDOC_LOCK_TIMEOUT_S=120
    elif [[ "$v" =~ ^[0-9]{1,5}$ ]]; then
        DEVDOC_LOCK_TIMEOUT_S=$((10#$v))
    else
        DEVDOC_LOCK_TIMEOUT_S=120
        if [ "$_DEVDOC_TIMEOUT_WARNED" -eq 0 ]; then
            warn "DEVAGENT_DEVDOC_LOCK_TIMEOUT='$v' is not a whole number of seconds (0-99999) - using 120"
            _DEVDOC_TIMEOUT_WARNED=1
        fi
    fi
}

# _devdoc_lock_field <lock path> <key> — one value from the holder record.
_devdoc_lock_field() {
    sed -n "s/^$2=//p" "$1/holder" 2>/dev/null | head -n 1
}

# _devdoc_lock_holder <lock path> — set _H_PID _H_HOST _H_ISSUE _H_START
# _H_CMD; rc 1 when the record is absent or unreadable.
_devdoc_lock_holder() {
    _H_PID="$(_devdoc_lock_field "$1" pid)"; _H_HOST="$(_devdoc_lock_field "$1" host)"
    _H_ISSUE="$(_devdoc_lock_field "$1" issue)"; _H_START="$(_devdoc_lock_field "$1" start)"
    _H_CMD="$(_devdoc_lock_field "$1" cmd)"
    [ -n "$_H_PID" ] && [ -n "$_H_START" ]
}

# devdoc_lock_acquire <devdoc_dir> <issue|-> <rerun text> — rc 0 holding the
# lock (DEVDOC_LOCK_OWNED=1, DEVAGENT_DEVDOC_LOCK_TOKEN exported) or reentrant
# (the env token equals the record's: DEVDOC_LOCK_OWNED=0, nothing created);
# rc 1 timed out; rc 2 no lock location. rc 1/2 print their message and never
# die — the caller decides what a refusal means.
devdoc_lock_acquire() {
    local devdoc_dir="$1" issue="${2:--}" rerun="$3" path rc=0 tok polls i=0 waited=0
    local prog; prog="$(_io_progname)"
    path="$(devdoc_lock_path "$devdoc_dir")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$prog: cannot determine the devdoc lock for $devdoc_dir: a .git entry exists but git rev-parse failed there - fix git (PATH, safe.directory) and re-run $rerun" >&2
        return 2
    fi
    tok="${DEVAGENT_DEVDOC_LOCK_TOKEN:-}"
    if [[ "$tok" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$(_devdoc_lock_field "$path" token)" = "$tok" ]; then
        DEVDOC_LOCK_OWNED=0; DEVDOC_LOCK_PATH="$path"
        return 0
    fi
    _devdoc_lock_timeout
    polls=$((DEVDOC_LOCK_TIMEOUT_S * 5))
    until mkdir "$path" 2>/dev/null; do
        if [ "$i" -ge "$polls" ]; then
            if _devdoc_lock_holder "$path"; then
                echo "$prog: devdoc lock $path is held by pid $_H_PID on $_H_HOST for $_H_ISSUE since $_H_START ($_H_CMD) - gave up after ${DEVDOC_LOCK_TIMEOUT_S}s (DEVAGENT_DEVDOC_LOCK_TIMEOUT). A killed run can leave it held. Only if no devagent run started at $_H_START is still running on $_H_HOST (check on that host, in that environment: the pid is that shell's own, not a Windows pid), remove it with: rm -f '$path/holder' && rmdir '$path' - then re-run $rerun" >&2
            else
                echo "$prog: devdoc lock $path is held (holder unknown: no readable record) - gave up after ${DEVDOC_LOCK_TIMEOUT_S}s (DEVAGENT_DEVDOC_LOCK_TIMEOUT). A killed run can leave it held, and a run that is just taking it has not written its record yet. Only if no devagent run is still running against this repository, remove it with: rm -f '$path/holder' && rmdir '$path' - then re-run $rerun" >&2
            fi
            return 1
        fi
        if [ "$waited" -eq 0 ]; then
            if _devdoc_lock_holder "$path"; then
                echo "$prog: waiting for devdoc lock $path (held by pid $_H_PID on $_H_HOST for $_H_ISSUE since $_H_START, $_H_CMD)" >&2
            else
                echo "$prog: waiting for devdoc lock $path (holder unknown)" >&2
            fi
            waited=1
        fi
        sleep 0.2
        i=$((i + 1))
    done
    tok="$$.$(date +%s).$RANDOM"
    printf 'token=%s\npid=%s\nhost=%s\nissue=%s\nstart=%s\ncmd=%s\n' \
        "$tok" "$$" "$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")" "$issue" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prog" > "$path/holder"
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
