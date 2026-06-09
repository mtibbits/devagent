#!/usr/bin/env bash
# scripts/lib/stacked.sh — resolve a stacked-child issue's parent branch (#34).
# A child stacked on an unmerged parent has baseline_sha == the parent branch's
# tip; basing its PR on default_baseline then pollutes the diff with the parent's
# commits. stacked_parent_branch resolves baseline_sha to a branch other than the
# default base so ship.sh can open the PR against the parent — GitHub's merge-base
# diff then shows only the child's delta, correct even if the parent later advances.
#
# Resolution order:
#   0. Non-stacked guard: baseline == tip(default_base) OR tip(<remote>/<default_base>)
#      → based on the default base, not a parent → empty. (Remote-checked because
#      baseline_sha comes from the remote base and the local one may lag.)
#   1. Local refs (authoritative). Candidate B (B ∉ {default_base, child}) iff
#        tip(B) == baseline                       (#34, child-independent), OR
#        merge-base(child, B) == baseline         (#48 advanced parent; only when
#                                                  a non-empty `child` is passed).
#   2. Remote-tracking refs (refs/remotes/<remote>/, "<remote>/" stripped on
#      output, <remote>/HEAD skipped): same predicate. Local wins, so tier 2 runs
#      only when tier 1 is empty (#41).
#   3. No match → empty → ship falls back to the default base (pre-#34, no regression).
#
# Disambiguation (_spb_choose): one candidate → take it; several with a `child`
# given → the unique ancestor of the child (the actual parent — a divergent
# sibling is not an ancestor); otherwise → first by refname order + a stderr
# warning (the remaining candidates are interchangeable bases or genuinely
# ambiguous; the warning makes any mis-base audible, never silent).
#
# `child` defaults to empty = exact Phase-1 (tip-only) behaviour, so callers that
# pass ≤4 args are unchanged. ship.sh passes the state branch (worktree-safe).
# A future authoritative `parent_branch` state field (see #48 design note) would
# slot in ahead of tier 1 and make the topology tiers its fallback.
#
# Requires io.sh sourced (for die/warn). Uses $DEVAGENT_GIT (defaults to git).
#
# Caller contract: the zero-diff guard must already have run (ship.sh exits before
# this for a zero-commit branch). Otherwise a child whose HEAD == baseline_sha
# would tip at baseline and could be returned as its own base.

# _spb_choose <src> <child> <strip_prefix> <candidate-ref>...
# Emit exactly one parent branch from candidate refs (each resolvable in <src>).
# One candidate → take it (silent). With a non-empty <child> and several
# candidates: the unique ancestor of <child> (a sibling sharing the baseline
# fork-point is NOT an ancestor); if 0 or ≥2 ancestors remain (interchangeable
# bases), first by refname order + a stderr warning. With no <child>, first by
# refname order, silently (legacy tip-only behaviour). <strip_prefix> (e.g. a
# remote name) is removed from the emitted name only; git operations use the
# full, resolvable ref.
_spb_choose() {
    local src="$1" child="$2" strip="$3"; shift 3
    local git="${DEVAGENT_GIT:-git}"
    local ref out=""
    if [ "$#" -eq 1 ] || [ -z "$child" ]; then
        out="$1"
    else
        local anc=()
        for ref in "$@"; do
            if "$git" -C "$src" merge-base --is-ancestor "$ref" "$child" 2>/dev/null; then
                anc+=("$ref")
            fi
        done
        if [ "${#anc[@]}" -eq 1 ]; then
            out="${anc[0]}"
        else
            out="$1"
            warn "stacked_parent_branch: $# branches resolve to the baseline; '${1#"$strip"/}' chosen by refname order — re-base the PR manually if that is not the parent (#48)"
        fi
    fi
    [ -n "$strip" ] && out="${out#"$strip"/}"
    printf '%s\n' "$out"
}

stacked_parent_branch() {
    local src="$1" baseline="$2" default_base="$3" remote="${4:-}" child="${5:-}"
    [ -n "$src" ] || die "stacked_parent_branch: source dir required"
    [ -n "$baseline" ] || return 0          # no baseline → not stacked
    local git="${DEVAGENT_GIT:-git}"

    # 0) Non-stacked guard (#48, incl. B1): baseline is the tip of the default
    #    base → based on the default base, never a parent. Resolve via the remote
    #    too — branch.sh sets baseline_sha from the REMOTE base (origin/master),
    #    so a lagging LOCAL default base would slip past a local-only check and
    #    let the merge-base scan mis-match a sibling that merely forked from the
    #    same base. Checking <remote>/<default_base> closes that hole.
    local def_ref d
    for def_ref in "$default_base" ${remote:+"$remote/$default_base"}; do
        d="$("$git" -C "$src" rev-parse --verify "${def_ref}^{commit}" 2>/dev/null)" || continue
        [ "$d" = "$baseline" ] && return 0
    done

    local cands=() objname short name mb

    # 1) Local branches (authoritative): tip == baseline, or (with a child)
    #    merge-base(child, B) == baseline.
    while IFS= read -r objname && IFS= read -r short; do
        [ -n "$short" ] || continue
        [ "$short" = "$default_base" ] && continue
        [ "$short" = "$child" ] && continue
        if [ "$objname" = "$baseline" ]; then
            cands+=("$short")
        elif [ -n "$child" ]; then
            mb="$("$git" -C "$src" merge-base "$child" "$short" 2>/dev/null)" || continue
            [ "$mb" = "$baseline" ] && cands+=("$short")
        fi
    done < <("$git" -C "$src" for-each-ref \
                --format='%(objectname)%0a%(refname:short)' refs/heads/)
    if [ "${#cands[@]}" -gt 0 ]; then
        _spb_choose "$src" "$child" "" "${cands[@]}"
        return 0
    fi

    # 2) Remote-tracking fallback (#41): git ops use the full <remote>/<name> ref;
    #    _spb_choose strips "<remote>/" from the emitted name.
    [ -n "$remote" ] || return 0
    cands=()
    while IFS= read -r objname && IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$remote" ] && continue       # skip <remote>/HEAD (short form == "<remote>")
        short="${name#"$remote"/}"
        [ "$short" = "$default_base" ] && continue
        [ "$short" = "$child" ] && continue
        if [ "$objname" = "$baseline" ]; then
            cands+=("$name")
        elif [ -n "$child" ]; then
            mb="$("$git" -C "$src" merge-base "$child" "$name" 2>/dev/null)" || continue
            [ "$mb" = "$baseline" ] && cands+=("$name")
        fi
    done < <("$git" -C "$src" for-each-ref \
                --format='%(objectname)%0a%(refname:short)' "refs/remotes/$remote/")
    if [ "${#cands[@]}" -gt 0 ]; then
        _spb_choose "$src" "$child" "$remote" "${cands[@]}"
        return 0
    fi
    return 0
}
