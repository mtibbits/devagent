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

# upstream_fetch <work_dir> <remote> — best-effort; never fatal. Silent no-op
# when <remote> is empty or not configured (only warn when a *configured*
# remote's fetch actually fails). #590: records which branch it took in
# UPSTREAM_FETCH_STATUS — "skipped" (no/unconfigured remote), "ok", or
# "failed" — so an artifact can say whether its counts follow a fresh fetch
# or the last-known remote state (setter-global: survives no `$(...)`). The
# fetch runs with GIT_TERMINAL_PROMPT=0: git's OWN credential prompt (HTTP
# auth) FAILS (→ "failed" + warn) instead of hanging an unattended step. Not
# covered: an ssh passphrase/host-key prompt, an askpass helper, or a remote
# that black-holes the connection — bounded calls are upstream_branch_tip's (#660).
# shellcheck disable=SC2034  # UPSTREAM_FETCH_STATUS is the return channel — read by rederive.sh (#590)
upstream_fetch() {
    local work_dir="$1" remote="${2:-}"
    UPSTREAM_FETCH_STATUS="skipped"
    [ -n "$remote" ] || return 0
    upstream_remote_configured "$work_dir" "$remote" || return 0
    if GIT_TERMINAL_PROMPT=0 "$DEVAGENT_GIT" -C "$work_dir" fetch --quiet "$remote" 2>/dev/null; then
        UPSTREAM_FETCH_STATUS="ok"
    else
        UPSTREAM_FETCH_STATUS="failed"
        warn "upstream_fetch: fetch of '$remote' failed; behind-counts may be stale"
    fi
    return 0
}

# _upstream_bounded <work_dir> <secs> <git args...>   (#660)
# The ONE home for a network call that must not hang an unattended chain: `timeout -k 5
# <secs>` (which also ends an ssh passphrase/host-key prompt, an askpass helper, or a
# black-holed connection) plus GIT_TERMINAL_PROMPT=0. git's stdout passes through; its
# stderr is dropped (the caller words its own diagnosis). Exit 124, or 137 after the KILL,
# means the bound expired. Needs timeout(1) on PATH; upstream_branch_tip checks that first.
_upstream_bounded() {
    local work_dir="$1" secs="$2"; shift 2
    GIT_TERMINAL_PROMPT=0 timeout -k 5 "$secs" "$DEVAGENT_GIT" -C "$work_dir" "$@" 2>/dev/null
}

# upstream_branch_tip <work_dir> <branch> <timeout_secs>   (#660)
# What `origin` says about <branch> right now. SETTER-GLOBALS — never command-substitute
# this (register Issue-282):
#   UPSTREAM_TIP      <sha>          origin's <branch>, as its ls-remote printed it
#                     (no-origin)    no `origin` remote: the single-tree case, nothing to ask
#                     (unreachable)  origin did not answer within the bound, or failed
#                     (unpushed)     origin answered that it has no <branch>
#   UPSTREAM_TIP_WHY  "no remote is named origin (remotes: …)" for a (no-origin) tree that
#                     HAS remotes (a `clone -o upstream`, a renamed remote: not the silent
#                     single-tree case, step-15 review); "timed out after <secs>s" |
#                     "git ls-remote exited <rc>" for
#                     (unreachable); "the refresh fetch exited <rc>" when a <sha> could not
#                     be fetched (the caller then cannot compare, and refuses)
# One question, by EXIT CODE: a bounded `ls-remote --exit-code origin refs/heads/<branch>`
# (0 = the tip, 2 = its documented "no matching ref", 124/137 = the bound expired) — the
# same command the preship verifier runs to attest. Then only when HEAD does not already
# contain that tip (behind, diverged, or the object is not here yet) is the ONE branch
# fetched, `+refs/heads/<branch>:refs/remotes/origin/<branch>` with --no-write-fetch-head
# (git >= 2.29): so the caller can tell behind from diverged, and the printed remedy's
# origin/<branch> is current even under a narrowed configured refspec (measured, Issue-660
# draft). That ref is the only thing this ever writes: no prune (a ref another refspec
# wrote under refs/remotes/origin/, e.g. pull-request heads, or one the user keeps after
# its branch went, survives), no FETCH_HEAD (a concurrent `git pull` in a shared tree
# reads it), and nothing at all when the tree is already fresh (whole-branch review and
# quality, 2026-09-27; the pruned all-heads fetch this replaced did all three).
# Returns 3 with UPSTREAM_TIP empty when origin exists but timeout(1) is not on PATH: the
# call cannot be bounded, and #660 exists to rule an unbounded one out. Every other
# outcome returns 0; the caller decides what a tip means (run-suite refuses a HEAD that
# does not contain it).
# Stated blind spot: in a SHALLOW clone a tip older than the shallow boundary is not
# visible as an ancestor, so the caller's is-ancestor refuses (the fail-closed direction).
# shellcheck disable=SC2034  # UPSTREAM_TIP/_WHY are the return channel — read by run-suite.sh (#660)
upstream_branch_tip() {
    local work_dir="$1" branch="$2" secs="$3" out="" rc=0
    UPSTREAM_TIP=""; UPSTREAM_TIP_WHY=""
    if ! upstream_remote_configured "$work_dir" origin; then
        UPSTREAM_TIP="(no-origin)"
        out="$("$DEVAGENT_GIT" -C "$work_dir" remote 2>/dev/null | tr '\n' ' ')" || out=""
        out="${out% }"
        [ -z "$out" ] || UPSTREAM_TIP_WHY="no remote is named origin (remotes: $out)"
        return 0
    fi
    command -v timeout >/dev/null 2>&1 || return 3
    out="$(_upstream_bounded "$work_dir" "$secs" ls-remote --exit-code origin "refs/heads/${branch}")" || rc=$?
    case "$rc" in
        0)       UPSTREAM_TIP="$(printf '%s\n' "$out" | awk -v r="refs/heads/${branch}" '$2 == r { print $1; exit }')" ;;
        2)       UPSTREAM_TIP="(unpushed)"; return 0 ;;
        124|137) UPSTREAM_TIP="(unreachable)"; UPSTREAM_TIP_WHY="timed out after ${secs}s"; return 0 ;;
        *)       UPSTREAM_TIP="(unreachable)"; UPSTREAM_TIP_WHY="git ls-remote exited $rc"; return 0 ;;
    esac
    if [ -z "$UPSTREAM_TIP" ]; then
        UPSTREAM_TIP="(unreachable)"; UPSTREAM_TIP_WHY="git ls-remote exited 0 without a refs/heads/${branch} line"
        return 0
    fi
    "$DEVAGENT_GIT" -C "$work_dir" merge-base --is-ancestor "$UPSTREAM_TIP" HEAD 2>/dev/null && return 0
    rc=0
    _upstream_bounded "$work_dir" "$secs" fetch --quiet --no-write-fetch-head origin \
        "+refs/heads/${branch}:refs/remotes/origin/${branch}" >/dev/null || rc=$?
    [ "$rc" -eq 0 ] || UPSTREAM_TIP_WHY="the refresh fetch exited $rc"
    return 0
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
