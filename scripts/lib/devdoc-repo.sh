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

# devdoc_mid_merge <dir> — rc 0 when the repository holding <dir> is mid-merge
# (MERGE_HEAD present): a pathspec commit is refused there (exit 128), and a
# plain commit would conclude someone else's merge.
devdoc_mid_merge() {
    devdoc_git_ro -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1
}
