#!/usr/bin/env bash
# scripts/lib/upstream.sh — detect drift of a base branch behind the upstream
# default branch, and probe branch/upstream conflicts without touching the
# working tree (issue #26). All helpers fail SAFE: unresolvable refs or an
# unavailable git feature yield "unknown" (empty / no-conflict), never a block.

: "${DEVAGENT_GIT:=git}"
# Fallback warn when sourced standalone (e.g. unit tests). The workflow scripts
# source lib/io.sh first, so the real warn is already defined there.
command -v warn >/dev/null 2>&1 || warn() { printf '%s\n' "$*" >&2; }

# upstream_remote_configured <work_dir> <remote> — rc 0 iff <remote> is configured in
# <work_dir>'s repo (#660). The ONE predicate for "is there a remote to ask": the skip in
# upstream_fetch and the (no-origin) arm of upstream_branch_tip both read it, so the two
# cannot disagree about which trees have an origin (register Issue-565).
upstream_remote_configured() {
    "$DEVAGENT_GIT" -C "$1" remote get-url "$2" >/dev/null 2>&1
}

# upstream_fetch <work_dir> <remote> [timeout_secs] — best-effort; never fatal. Silent
# no-op when <remote> is empty or not configured (only warn when a *configured*
# remote's fetch actually fails). #590: records which branch it took in
# UPSTREAM_FETCH_STATUS — "skipped" (no/unconfigured remote), "ok", or
# "failed" — so an artifact can say whether its counts follow a fresh fetch
# or the last-known remote state (setter-global: survives no `$(...)`). The
# fetch runs with GIT_TERMINAL_PROMPT=0: git's OWN credential prompt (HTTP
# auth) FAILS (→ "failed" + warn) instead of hanging an unattended step. Not
# covered WITHOUT a bound: an ssh passphrase/host-key prompt, an askpass helper,
# or a remote that black-holes the connection.
# #660: WITH [timeout_secs] this is the FRESHNESS fetch — bounded (`timeout -k 5
# <secs>`, which also ends those three hangs), pruned (--prune), and given the explicit
# refspec `+refs/heads/*:refs/remotes/<remote>/*`. Its one caller, upstream_branch_tip,
# reads refs/remotes/<remote>/<branch> as the remote's present truth. Without those two,
# a tracking ref for a branch deleted at the remote, or one a narrowed configured
# refspec never refreshes, answers with a stale sha (both measured, Issue-660 draft).
# The configured refspec itself is not changed, but a bounded call does WRITE: it
# refreshes every refs/remotes/<remote>/*, prunes, writes FETCH_HEAD, and on a narrowed
# clone creates tracking refs the configured refspec would not (improve, 2026-09-27).
# With no bound the fetch is the pre-#660 one, argv for argv. UPSTREAM_FETCH_RC is the fetch's exit status (124, or 137 after
# the KILL, when the bound expired). A bounded call needs timeout(1) on PATH;
# upstream_branch_tip checks that before calling.
# shellcheck disable=SC2034  # UPSTREAM_FETCH_STATUS/_RC are the return channel — read by rederive.sh (#590) and upstream_branch_tip (#660)
upstream_fetch() {
    local work_dir="$1" remote="${2:-}" secs="${3:-}"
    local -a bound=() what=()
    UPSTREAM_FETCH_STATUS="skipped"; UPSTREAM_FETCH_RC=0
    [ -n "$remote" ] || return 0
    upstream_remote_configured "$work_dir" "$remote" || return 0
    if [ -n "$secs" ]; then
        bound=(timeout -k 5 "$secs")
        what=(--prune "$remote" "+refs/heads/*:refs/remotes/$remote/*")
    else
        what=("$remote")
    fi
    if GIT_TERMINAL_PROMPT=0 ${bound[@]+"${bound[@]}"} "$DEVAGENT_GIT" -C "$work_dir" fetch --quiet "${what[@]}" 2>/dev/null; then
        UPSTREAM_FETCH_STATUS="ok"
    else
        UPSTREAM_FETCH_RC=$?
        UPSTREAM_FETCH_STATUS="failed"
        warn "upstream_fetch: fetch of '$remote' failed; behind-counts may be stale"
    fi
    return 0
}

# upstream_branch_tip <work_dir> <branch> <timeout_secs>   (#660)
# What `origin` says about <branch> right now. SETTER-GLOBALS — never command-substitute
# this (register Issue-282):
#   UPSTREAM_TIP      <sha>          refs/remotes/origin/<branch> after the FRESHNESS fetch
#                     (no-origin)    no `origin` remote: the single-tree case, nothing to ask
#                     (unreachable)  the fetch failed, or its bound expired
#                     (unpushed)     the fetch succeeded and origin has no <branch>
#   UPSTREAM_TIP_WHY  (unreachable) only: "timed out after <secs>s" | "git fetch exited <rc>"
# Returns 3 with UPSTREAM_TIP empty when origin exists but timeout(1) is not on PATH: the
# fetch cannot be bounded, and #660 exists to rule an unbounded one out. Every other
# outcome returns 0; the caller decides what a tip means (run-suite refuses a HEAD that
# does not contain it).
# Stated blind spot: in a SHALLOW clone a tip older than the shallow boundary is not
# visible as an ancestor, so the caller's is-ancestor refuses (the fail-closed direction).
# shellcheck disable=SC2034  # UPSTREAM_TIP/_WHY are the return channel — read by run-suite.sh (#660)
upstream_branch_tip() {
    local work_dir="$1" branch="$2" secs="$3" tip=""
    UPSTREAM_TIP=""; UPSTREAM_TIP_WHY=""
    if ! upstream_remote_configured "$work_dir" origin; then
        UPSTREAM_TIP="(no-origin)"; return 0
    fi
    command -v timeout >/dev/null 2>&1 || return 3
    # 2>/dev/null: upstream_fetch's warn speaks of behind-counts; the caller words its own.
    upstream_fetch "$work_dir" origin "$secs" 2>/dev/null
    if [ "$UPSTREAM_FETCH_STATUS" != ok ]; then
        UPSTREAM_TIP="(unreachable)"
        case "$UPSTREAM_FETCH_RC" in
            124|137) UPSTREAM_TIP_WHY="timed out after ${secs}s" ;;
            *)       UPSTREAM_TIP_WHY="git fetch exited $UPSTREAM_FETCH_RC" ;;
        esac
        return 0
    fi
    tip="$("$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}" 2>/dev/null)" || tip=""
    UPSTREAM_TIP="${tip:-(unpushed)}"
}

# upstream_behind_count <work_dir> <base_ref> <upstream_ref>
#   echoes # commits in <upstream_ref> not reachable from <base_ref>.
#   Empty string if either ref can't be resolved (caller: unknown -> skip).
upstream_behind_count() {
    local work_dir="$1" base="$2" up="$3"
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || { printf ''; return 0; }
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$up^{commit}"   >/dev/null 2>&1 || { printf ''; return 0; }
    "$DEVAGENT_GIT" -C "$work_dir" rev-list --count "$base..$up" 2>/dev/null || printf ''
}

# is_fast_forward <work_dir> <from_ref> <to_ref>
#   return 0 if <from_ref> is an ancestor of <to_ref> (so <from_ref> can be
#   fast-forwarded to <to_ref>); 1 otherwise — including unresolvable refs
#   (fail safe: "can't prove a clean FF" -> caller hard-stops rather than
#   pushing into a guaranteed-or-possible non-FF reject).
is_fast_forward() {
    local work_dir="$1" from="$2" to="$3"
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$from^{commit}" >/dev/null 2>&1 || return 1
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$to^{commit}"   >/dev/null 2>&1 || return 1
    "$DEVAGENT_GIT" -C "$work_dir" merge-base --is-ancestor "$from" "$to"
}

# branch_conflicts_upstream <work_dir> <branch> <upstream_ref>
#   return 0 (true)  if merging <upstream_ref> into <branch> would conflict;
#   return 1 (false) if it merges cleanly OR cannot be determined (fail safe).
#   Uses `git merge-tree --write-tree` (git >= 2.38); no working-tree mutation.
branch_conflicts_upstream() {
    local work_dir="$1" branch="$2" up="$3" rc
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$branch^{commit}" >/dev/null 2>&1 || return 1
    "$DEVAGENT_GIT" -C "$work_dir" rev-parse --verify --quiet "$up^{commit}"     >/dev/null 2>&1 || return 1
    "$DEVAGENT_GIT" -C "$work_dir" merge-tree --write-tree "$branch" "$up" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 1 ] && return 0   # exactly 1 = conflicts; 0 = clean; >1 = error -> fail safe
    return 1
}
