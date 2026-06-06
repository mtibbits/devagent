#!/usr/bin/env bash
# scripts/lib/upstream.sh — detect drift of a base branch behind the upstream
# default branch, and probe branch/upstream conflicts without touching the
# working tree (issue #26). All helpers fail SAFE: unresolvable refs or an
# unavailable git feature yield "unknown" (empty / no-conflict), never a block.

: "${DEVAGENT_GIT:=git}"
# Fallback warn when sourced standalone (e.g. unit tests). The workflow scripts
# source lib/io.sh first, so the real warn is already defined there.
command -v warn >/dev/null 2>&1 || warn() { printf '%s\n' "$*" >&2; }

# upstream_fetch <work_dir> <remote> — best-effort; never fatal. Silent no-op
# when <remote> is empty or not configured (only warn when a *configured*
# remote's fetch actually fails).
upstream_fetch() {
    local work_dir="$1" remote="${2:-}"
    [ -n "$remote" ] || return 0
    "$DEVAGENT_GIT" -C "$work_dir" remote get-url "$remote" >/dev/null 2>&1 || return 0
    "$DEVAGENT_GIT" -C "$work_dir" fetch --quiet "$remote" 2>/dev/null \
        || warn "upstream_fetch: fetch of '$remote' failed; behind-counts may be stale"
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
