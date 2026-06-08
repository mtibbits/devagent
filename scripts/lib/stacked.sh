#!/usr/bin/env bash
# scripts/lib/stacked.sh — resolve a stacked-child issue's parent branch (#34).
# A child stacked on an unmerged parent has baseline_sha == the parent branch's
# tip; basing its PR on default_baseline then pollutes the diff with the parent's
# commits. stacked_parent_branch resolves baseline_sha to a LOCAL branch other
# than the default base so ship.sh can open the PR against the parent — GitHub's
# merge-base diff then shows only the child's delta, correct even if the parent
# later advances.
#
# Returns the first matching branch by refname order; if several branches tip at
# baseline_sha, that may not be the parent (rare — a branch parked at the parent
# tip). Limitation: if the parent advanced past baseline_sha after the child was
# cut, no branch tip matches and this returns empty → ship falls back to the
# default base (pre-#34 behavior, no regression). Local-only (refs/heads/): the
# parent's local branch persists after its cleanup; a future enhancement could
# also search refs/remotes/<remote>/.
#
# Requires io.sh sourced (for die). Uses $DEVAGENT_GIT (defaults to git).
#
# Caller contract: the zero-diff guard must already have run (ship.sh exits before
# this for a zero-commit branch). Otherwise a child whose HEAD == baseline_sha
# would tip at baseline and could be returned as its own base.

stacked_parent_branch() {
    local src="$1" baseline="$2" default_base="$3"
    [ -n "$src" ] || die "stacked_parent_branch: source dir required"
    [ -n "$baseline" ] || return 0          # no baseline → not stacked
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$default_base" ] && continue   # the default base is not a parent
        printf '%s\n' "$name"
        return 0
    done < <("${DEVAGENT_GIT:-git}" -C "$src" for-each-ref \
                --format='%(refname:short)' --points-at "$baseline" refs/heads/)
    return 0
}
