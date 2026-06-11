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
# Two #154 guards run on every qualified candidate, in both tiers, BEFORE it is
# collected (live regression: PR #152 based on PR #147's dead branch → reland #153):
#   Layer A — degenerate drop: a candidate whose tip is an ancestor of the base tip
#     adds nothing over the base → drop + warn (a stale ref pinned at an old base
#     tip after the base advanced). base_tip is remote-preferred (see tier 0).
#   Layer B — staleness: a LOCAL candidate strictly behind its remote-tracking
#     counterpart is stale → skip (defer to the real remote tip in tier 2) + warn;
#     local-ahead/equal (unpushed commits) is kept; diverged is kept + a loud warn.
#     Remote-arg-gated — with no <remote> arg there is no counterpart, so Layer B is
#     a no-op (Layer A still applies). Neither guard can see a sibling whose PR
#     already squash-merged on its real tip; ship.sh's forge merged-PR-head check
#     (#154 Layer C) is the decisive backstop for that route.
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

# _spb_adds_nothing <src> <candidate-objname> <base-tip>
# True (exit 0) iff the candidate's tip is an ancestor of the base tip — i.e. it
# contributes nothing over the default base, so it is not a stacked parent (#154
# Layer A). Catches a stale local ref pinned at an old base tip after the base
# advanced past it (live: PR #152 based on PR #147's dead branch → reland #153).
# Empty base_tip, or any git error (`--is-ancestor` exits ≠0,1 on a bad ref), →
# false (keep), failing toward the pre-#154 behaviour; ship.sh's forge merged-PR-head
# check (#154 Layer C) is the decisive backstop for the squash-merged-sibling route
# that no git-only predicate can see.
_spb_adds_nothing() {
    local src="$1" cand="$2" base_tip="$3"
    local git="${DEVAGENT_GIT:-git}"
    [ -n "$base_tip" ] || return 1
    "$git" -C "$src" merge-base --is-ancestor "$cand" "$base_tip" 2>/dev/null
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
    # base_tip is captured here for Layer A (#154); the loop visits the local base
    # first then <remote>/<base>, so base_tip ends remote-preferred (the ref
    # branch.sh sets baseline_sha from), with a local fallback.
    local def_ref d base_tip=""
    for def_ref in "$default_base" ${remote:+"$remote/$default_base"}; do
        d="$("$git" -C "$src" rev-parse --verify "${def_ref}^{commit}" 2>/dev/null)" || continue
        base_tip="$d"
        [ "$d" = "$baseline" ] && return 0
    done

    local cands=() objname short name mb q rtip

    # 1) Local branches (authoritative): tip == baseline, or (with a child)
    #    merge-base(child, B) == baseline.
    while IFS= read -r objname && IFS= read -r short; do
        [ -n "$short" ] || continue
        [ "$short" = "$default_base" ] && continue
        [ "$short" = "$child" ] && continue
        q=0
        if [ "$objname" = "$baseline" ]; then
            q=1
        elif [ -n "$child" ]; then
            mb="$("$git" -C "$src" merge-base "$child" "$short" 2>/dev/null)" || continue
            [ "$mb" = "$baseline" ] && q=1
        fi
        [ "$q" = 1 ] || continue
        # Layer A (#154): a qualified candidate whose tip is an ancestor of the base
        # adds nothing over it — drop + warn (never a silent mis-base).
        if _spb_adds_nothing "$src" "$objname" "$base_tip"; then
            warn "stacked_parent_branch: candidate '$short' tip is an ancestor of the base (adds nothing) — not a stacked parent; basing on the default base (#154; live PR #152/#153)"
            continue
        fi
        # Layer B (#154): a LOCAL candidate strictly behind its remote-tracking
        # counterpart is stale (the live bug: a local ref pinned at the old tip while
        # the remote — and its merged PR — moved on). Skip it so resolution falls
        # through to tier 2 on the real remote tip. Local-ahead/equal (unpushed
        # review/redmr commits) is authoritative → keep silently. Diverged → keep but
        # warn loudly (operator decides; never a silent default-base fallback).
        # Remote-arg-gated: with no <remote> there is no counterpart to compare.
        if [ -n "$remote" ]; then
            rtip="$("$git" -C "$src" rev-parse --verify "refs/remotes/$remote/$short^{commit}" 2>/dev/null)" || rtip=""
            if [ -n "$rtip" ] && [ "$rtip" != "$objname" ]; then
                if "$git" -C "$src" merge-base --is-ancestor "$objname" "$rtip" 2>/dev/null; then
                    warn "stacked_parent_branch: local '$short' is behind its remote counterpart (stale) — deferring to refs/remotes/$remote/$short (#154; live PR #152/#153)"
                    continue
                elif ! "$git" -C "$src" merge-base --is-ancestor "$rtip" "$objname" 2>/dev/null; then
                    warn "stacked_parent_branch: local '$short' and refs/remotes/$remote/$short have diverged — using the local ref; verify the PR base (#154)"
                fi
            fi
        fi
        cands+=("$short")
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
        q=0
        if [ "$objname" = "$baseline" ]; then
            q=1
        elif [ -n "$child" ]; then
            mb="$("$git" -C "$src" merge-base "$child" "$name" 2>/dev/null)" || continue
            [ "$mb" = "$baseline" ] && q=1
        fi
        [ "$q" = 1 ] || continue
        # Layer A (#154): same degenerate-candidate drop as tier 1, on the full
        # <remote>/<name> ref; warn with the stripped short name.
        if _spb_adds_nothing "$src" "$objname" "$base_tip"; then
            warn "stacked_parent_branch: candidate '$short' tip is an ancestor of the base (adds nothing) — not a stacked parent; basing on the default base (#154; live PR #152/#153)"
            continue
        fi
        cands+=("$name")
    done < <("$git" -C "$src" for-each-ref \
                --format='%(objectname)%0a%(refname:short)' "refs/remotes/$remote/")
    if [ "${#cands[@]}" -gt 0 ]; then
        _spb_choose "$src" "$child" "$remote" "${cands[@]}"
        return 0
    fi
    return 0
}
