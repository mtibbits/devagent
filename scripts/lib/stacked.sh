#!/usr/bin/env bash
# scripts/lib/stacked.sh — resolve a stacked-child issue's parent branch (#34).
# A child stacked on an unmerged parent has baseline_sha == the parent branch's
# tip; basing its PR on default_baseline then pollutes the diff with the parent's
# commits. stacked_parent_branch resolves baseline_sha to a LOCAL branch other
# than the default base so ship.sh can open the PR against the parent — GitHub's
# merge-base diff then shows only the child's delta, correct even if the parent
# later advances.
#
# Resolution order (#41): local branches (refs/heads/) first, then — when a
# `remote` arg is given and no local branch matches — remote-tracking refs
# (refs/remotes/<remote>/, the "<remote>/" prefix stripped, <remote>/HEAD
# skipped). Returns the first match by refname order.
#
# Phase-2 limitations (tracked in a separate issue): if several branches tip at
# baseline_sha, the first by refname order may not be the actual parent (rare —
# a branch parked at the parent tip); and if the parent advanced past
# baseline_sha after the child was cut, no tip matches and this returns empty →
# ship falls back to the default base (pre-#34 behavior, no regression).
#
# Requires io.sh sourced (for die). Uses $DEVAGENT_GIT (defaults to git).
#
# Caller contract: the zero-diff guard must already have run (ship.sh exits before
# this for a zero-commit branch). Otherwise a child whose HEAD == baseline_sha
# would tip at baseline and could be returned as its own base.

stacked_parent_branch() {
    local src="$1" baseline="$2" default_base="$3" remote="${4:-}"
    [ -n "$src" ] || die "stacked_parent_branch: source dir required"
    [ -n "$baseline" ] || return 0          # no baseline → not stacked
    local name
    # 1) Local branches (authoritative — prefer over remotes).
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$default_base" ] && continue   # the default base is not a parent
        printf '%s\n' "$name"
        return 0
    done < <("${DEVAGENT_GIT:-git}" -C "$src" for-each-ref \
                --format='%(refname:short)' --points-at "$baseline" refs/heads/)
    # 2) Remote-tracking fallback (#41): the parent's local branch may be gone
    #    (fresh clone / deleted) while it still exists on the push remote. Strip
    #    the "<remote>/" prefix so the result is usable as a PR --base.
    [ -n "$remote" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$remote" ] && continue      # skip the symbolic <remote>/HEAD (its short form is "<remote>")
        name="${name#"$remote"/}"               # origin/feat/parent → feat/parent
        [ "$name" = "$default_base" ] && continue
        printf '%s\n' "$name"
        return 0
    done < <("${DEVAGENT_GIT:-git}" -C "$src" for-each-ref \
                --format='%(refname:short)' --points-at "$baseline" "refs/remotes/$remote/")
    return 0
}
