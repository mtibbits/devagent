#!/usr/bin/env bash
# scripts/preship-verified-head.sh — record the head a passing preship verified
# (#885). Usage: preship-verified-head.sh (pin|record|forward) <project> [issue]
#
# mergemr (step 20) merges only at `verified_head`: the commit the last PASSING
# preship actually read. preship's verifier runs in its own model turn, and no
# shell variable survives a turn (register Issue-578), so the head is carried in
# issue state instead:
#   pin     persists HEAD as `preship_pin_head` and prints its full SHA — the
#           literal diff spec the verifier is handed is `<baseline_sha>..<SHA>`.
#   record  (after all five verifications PASS) reads the pin back and compares
#           it with HEAD: no pin refuses; a moved HEAD refuses and records
#           nothing (the verifier read a different commit than HEAD is now);
#           else writes `verified_head` and `verified_by = preship`, clears the
#           pin, logs `preship: verified_head <sha40>`.
#   forward (#1125; [project.<p>.merge_forward] verify = "ci") re-records
#           `verified_head` (`verified_by = forward`) after a merge-forward that
#           only re-applies git's own merge of the base: HEAD's first-parent path
#           from verified_head is two-parent merges of base commits, baseline_sha
#           is the base commit T the last one brought in, no merge driver is set,
#           mr.md names no merge gate, and HEAD's tree equals `git merge-tree` of
#           verified_head and T at every path, except keep-both of a conflict in an
#           append_only file (lib/merge-forward-hunks.py). Every refusal of those
#           conditions is `forward refused (<condition>): <detail>`, exit 1, nothing
#           written; bad config and git failures die. It first fetches
#           default_baseline's branch once, bounded by DEVAGENT_REBASELINE_FETCH_SECS
#           (20); a failed fetch warns and uses the last-known ref.
#           Success logs `forward: verified_head <sha40> from <old7> (git's merge
#           of <T7>; no conflict | both sides kept in <paths>)`. mergemr merges a
#           forwarded head only on green CI (rule 17).
# All three verbs refuse unless the tree's HEAD is the issue branch (register
# Issue-69): a head on another branch verifies nothing about the PR.
#
# Clearing a stop (clear_mergemr_stop). A post-ship preship is the remedy
# mergemr's rules 10 (no verified head), 11 (head not verified), 14 (conflict,
# merged forward), 15 (red CI, fixed) and forward's rule 17 name, and the remedy
# for a FAILED post-ship preship that stopped the mergemr row; `forward` is the
# remedy rule 14 names when it applies, and for a rule 11 naming this head. Each
# clears that stop — and only that one — when ALL hold: ship is [x] (in the
# active revision block), the mergemr row is [!], STUCK's `Step:` names mergemr,
# its `Reason:` matches the verb's prefix (record: `mergemr rule 10|11|14|15: `,
# `mergemr rule 17: head <sha7> was recorded by forward ` or `preship: `;
# forward: `mergemr rule 14: ` or `mergemr rule 11: PR head <HEAD7> was not
# verified; `), and the [!] row checklist-unstuck.sh will flip (it is
# line-based, Issue-587: the active block's first [!]) IS mergemr. It then runs
# `checklist-unstuck.sh --pending` and logs `<verb tag>: cleared mergemr stop
# (<reason, up to 60 chars>)`. Every other [!] (rule 9, a mergetoall stop, …)
# stays for /devagent:unstuck.
#
# The issue resolves as mergetoall's does (pin or state, never a scan, #240);
# the tree is the issue's (active_tree_resolve, register Issue-590/595).
# The name is not preship.sh on purpose: a script named after a step would be
# read as that step's script by role detection (register Issue-812).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/quarantine.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
# #1125 (forward): the merge_forward config and predicates; ci.sh for _ci_secs, which
# sources upstream.sh (upstream_fetch_base).
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/merge-forward.sh"
. "$DEVAGENT_ROOT/scripts/lib/ci.sh"

: "${DEVAGENT_GIT:=git}"

usage() {
    echo "usage: preship-verified-head.sh (pin|record|forward) <project> [issue]" >&2
    exit 2
}

verb="${1:-}"
case "$verb" in pin|record|forward) : ;; *) usage ;; esac

project="${2:-}"
[ -n "$project" ] || die "preship-verified-head: project required"
config_is_project "$project" || die "preship-verified-head: unknown project '$project'"
quarantine_guard_marker "preship-verified-head" "$project" "${3:-}"

issue_arg="${3:-}"
if [ -z "$issue_arg" ]; then
    # #240: never act on a scan-GUESSED issue — pin/state only, else die.
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "preship-verified-head: no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "preship-verified-head: issue_dir not set or missing"
branch="$(state_ctx_get "$project" branch "$issue_arg" 2>/dev/null || true)"
branch="${branch//$'\r'/}"
[ -n "$branch" ] || die "preship-verified-head: no branch in state for $issue_arg"

active_tree_resolve "$project" "$issue_arg"     # setter-globals; never $( … )
tree="$ACTIVE_TREE_DIR"
g() { "$DEVAGENT_GIT" -C "$tree" "$@"; }

# HEAD must be the issue branch. The full ref, stripped by hand (`--short` prints
# heads/<b> when a tag shares the name; run-suite.sh #660).
ref_rc=0
head_ref="$(g symbolic-ref --quiet HEAD 2>/dev/null)" || ref_rc=$?
case "$ref_rc:$head_ref" in
    0:refs/heads/?*) on="${head_ref#refs/heads/}" ;;
    1:*) die "preship-verified-head: HEAD is detached at $(g rev-parse --short HEAD 2>/dev/null || echo '?'), not on the issue branch $branch (in $tree)" ;;
    *)   die "preship-verified-head: could not read which branch HEAD is on in $tree (git symbolic-ref exited $ref_rc)" ;;
esac
[ "$on" = "$branch" ] || die "preship-verified-head: HEAD is on $on, not the issue branch $branch (in $tree)"

head="$(g rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" \
    || die "preship-verified-head: cannot resolve HEAD in $tree"

if [ "$verb" = pin ]; then
    state_ctx_set_many "$project" "$issue_arg" str preship_pin_head "$head"
    printf '%s\n' "$head"
    exit 0
fi

# ---- clearing a mergemr stop the run just remedied -----------------------------
# clear_mergemr_stop <tag> <regex>: clears the mergemr stop whose STUCK `Reason:`
# matches <regex>, under the conditions in this file's header ("Clearing a stop").
clear_mergemr_stop() {
    local tag="$1" clear_re="$2" cl="$issue_dir/checklist.md" stuck="$issue_dir/STUCK"
    local ship_g mm_g stuck_step reason found row at msg
    [ -f "$cl" ] && [ -f "$stuck" ] || return 0
    ship_g="$(checklist_step_state_by_name "$cl" ship 2>/dev/null || true)"
    mm_g="$(checklist_step_state_by_name "$cl" mergemr 2>/dev/null || true)"
    [ "$ship_g" = x ] && [ "$mm_g" = '!' ] || return 0

    stuck_step="$(sed -n 's/^Step:[[:space:]]*//p' "$stuck" | head -n 1)"
    stuck_step="${stuck_step//$'\r'/}"
    reason="$(sed -n 's/^Reason:[[:space:]]*//p' "$stuck" | head -n 1)"
    reason="${reason//$'\r'/}"
    [ "${stuck_step##* }" = mergemr ] || return 0
    [[ "$reason" =~ $clear_re ]] || return 0

    # checklist-unstuck.sh flips the active block's FIRST [!] by line (#587); clear
    # only when that row is mergemr, so no other stop is flipped in its place.
    found="$(checklist_find_glyph_line "$cl" '!')"
    row="${found%%:*}"
    at=""
    [ -n "$row" ] && at="$(checklist_step_name_at_line "$cl" "$row" 2>/dev/null || true)"
    if [ "$at" != mergemr ]; then
        warn "preship-verified-head: the first [!] row is '${at:-?}', not mergemr; the mergemr stop is left for /devagent:unstuck"
        return 0
    fi

    bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$issue_dir"
    msg="cleared mergemr stop (${reason:0:60})"
    log_append "$issue_dir" "$tag" "$msg"
    echo "$tag: $msg"
}

# ---- forward (#1125) ------------------------------------------------------------
if [ "$verb" = forward ]; then
    recipe='re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship'
    refuse() { die "preship-verified-head: forward refused ($1): $2"; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # (a) enabled. merge_forward_resolve dies on a bad value (Issue-780).
    merge_forward_resolve "$project"
    if [ "$MF_VERIFY" != ci ]; then
        vraw="$(config_get_project_field "$project" merge_forward.verify 2>/dev/null)" || vraw=absent
        refuse enabled "[project.$project.merge_forward] verify is not \"ci\" (${vraw//$'\r'/}); $recipe"
    fi

    # (b) recorded: a verified head, and a clean tree to compare.
    vh="$(state_ctx_get "$project" verified_head "$issue_arg" 2>/dev/null)" || vh=""
    vh="${vh//$'\r'/}"
    [ -n "$vh" ] || refuse recorded "no verified_head recorded; $recipe"
    vh40="$(g rev-parse --verify --quiet "${vh}^{commit}" 2>/dev/null)" \
        || refuse recorded "verified_head ${vh:0:7} is not a commit in $tree; $recipe"
    st_rc=0
    st="$(g status --porcelain --untracked-files=no 2>/dev/null)" || st_rc=$?
    [ "$st_rc" -eq 0 ] || die "preship-verified-head: git status exited $st_rc in $tree"
    [ -z "$st" ] || refuse recorded "uncommitted changes in $tree; commit or discard them first"

    # (c) shape: HEAD's first-parent path from verified_head is two-parent merges of
    # commits on the base, and baseline_sha is the base commit the last one brought in.
    base_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
    base_ref="${base_ref//$'\r'/}"
    [ -n "$base_ref" ] || die "preship-verified-head: no default_baseline configured for '$project'"
    _ci_secs DEVAGENT_REBASELINE_FETCH_SECS 20
    upstream_fetch_base "$tree" "$base_ref" "$_CI_SECS"     # setter-globals; never $( … )
    stale=""
    case "$BASE_FETCH" in
        failed|notimeout)
            warn "preship-verified-head: could not fetch '$BASE_FETCH_REMOTE' ($BASE_FETCH_WHY); using the last-known $base_ref"
            stale=" (the fetch failed, so $base_ref may be stale)" ;;
    esac

    rl_rc=0
    walk="$(g rev-list --first-parent --parents "$vh40..$head" 2>/dev/null)" || rl_rc=$?
    [ "$rl_rc" -eq 0 ] || die "preship-verified-head: git rev-list exited $rl_rc in $tree"
    if [ -z "$walk" ]; then
        [ "$head" = "$vh40" ] \
            && refuse shape "HEAD is verified_head ${vh40:0:7}; there is no merge-forward to verify"
        refuse shape "HEAD's first-parent path does not reach verified_head ${vh40:0:7}; $recipe"
    fi
    mapfile -t commits <<<"$walk"
    seconds=()
    for line in "${commits[@]}"; do
        read -r -a f <<<"$line"
        np=$(( ${#f[@]} - 1 ))
        [ "$np" -ge 2 ] || refuse shape "${f[0]:0:7} on HEAD's first-parent path is not a merge; $recipe"
        [ "$np" -eq 2 ] || refuse shape "${f[0]:0:7} has $np parents; only two-parent merges are forwarded"
        seconds+=("${f[0]} ${f[2]}")
    done
    read -r -a f <<<"${commits[-1]}"
    [ "${f[1]}" = "$vh40" ] \
        || refuse shape "HEAD's first-parent path does not reach verified_head ${vh40:0:7}; $recipe"
    tip="$(g rev-parse --verify --quiet "${base_ref}^{commit}" 2>/dev/null)" \
        || refuse shape "cannot resolve $base_ref in $tree"
    for pair in "${seconds[@]}"; do
        c="${pair% *}" p2="${pair#* }" anc_rc=0
        g merge-base --is-ancestor "$p2" "$tip" 2>/dev/null || anc_rc=$?
        case "$anc_rc" in
            0) : ;;
            1) refuse shape "second parent ${p2:0:7} of ${c:0:7} is not on $base_ref (${tip:0:7})$stale" ;;
            *) die "preship-verified-head: git merge-base --is-ancestor exited $anc_rc in $tree" ;;
        esac
    done
    read -r -a f <<<"${commits[0]}"
    T="${f[2]}"
    b="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null)" || b=""
    b="${b//$'\r'/}"
    b40=""
    [ -n "$b" ] && b40="$(g rev-parse --verify --quiet "${b}^{commit}" 2>/dev/null)" || true
    [ "$b40" = "$T" ] \
        || refuse shape "baseline_sha ${b:0:7} is not ${T:0:7}, the base commit HEAD's last merge brought in; run rebaseline.sh"

    # (d) git's own merge of verified_head and T must equal HEAD's tree.
    m7="${vh40:0:7} and ${T:0:7}"
    mt_rc=0
    merge_forward_merge "$tree" "$vh40" "$T" || mt_rc=$?
    case "$mt_rc" in
        2) refuse merge "git merge-tree exited $MF_MERGE_RC on $m7" ;;
        3) refuse merge "a conflicted path contains a newline" ;;
        4) refuse merge "git reports a conflict in its merge of $m7 but names no conflicted path" ;;
    esac

    # A merge driver (merge=union, …) would hide a conflict from this comparison.
    dr_rc=0
    merge_forward_drivers "$tree" "$MF_MTREE" || dr_rc=$?
    case "$dr_rc" in
        1) refuse merge "$MF_DRIVER_PATH has merge=$MF_DRIVER_VALUE (git check-attr); a merge driver hides conflicts from git's merge" ;;
        2) die "preship-verified-head: $MF_DRIVER_WHY in $tree" ;;
        3|4) refuse merge "$MF_DRIVER_WHY" ;;
    esac

    # Each conflicted path must be a listed append-only file git merged as text.
    # shellcheck disable=SC2153  # MF_CONFLICTED is merge_forward_merge's
    for cpath in "${MF_CONFLICTED[@]}"; do
        merge_forward_listed "$cpath" \
            || refuse merge "$cpath conflicts in git's merge and is not in merge_forward.append_only"
        [ "${MF_CONFLICT[$cpath]}" = text ] \
            || refuse merge "$cpath has a conflict git did not merge as text"
    done

    # HEAD's tree must equal git's merge at every path but the conflicted ones.
    dt_rc=0
    # --ignore-submodules=none: submodule.<name>.ignore=all would hide a gitlink change.
    g diff-tree -r -z --no-renames --ignore-submodules=none --raw "$MF_MTREE" "$head" >"$tmp/dt" 2>/dev/null || dt_rc=$?
    [ "$dt_rc" -eq 0 ] || die "preship-verified-head: git diff-tree exited $dt_rc in $tree"
    mapfile -d '' dt <"$tmp/dt"
    [ $(( ${#dt[@]} % 2 )) -eq 0 ] \
        || die "preship-verified-head: git diff-tree returned an odd field count (${#dt[@]}) in $tree"
    for (( i = 0; i < ${#dt[@]}; i += 2 )); do
        meta="${dt[i]#:}" dpath="${dt[i+1]}"
        read -r srcm dstm _ <<<"$meta"
        if [ -z "${MF_CONFLICT[$dpath]+x}" ] || [ "$dstm" = 000000 ]; then
            refuse merge "$dpath differs from git's merge of $m7"
        fi
        [ "$srcm" = "$dstm" ] || refuse merge "$dpath changes mode"
    done

    # Each conflicted path: the append-only hunk checker on git's merged blob and HEAD's.
    hunks="${DEVAGENT_MF_HUNKS:-$DEVAGENT_ROOT/scripts/lib/merge-forward-hunks.py}"
    for cpath in "${MF_CONFLICTED[@]}"; do
        g cat-file blob "$MF_MTREE:$cpath" >"$tmp/merged" 2>/dev/null \
            || die "preship-verified-head: cannot read $cpath from git's merge in $tree"
        g cat-file blob "$head:$cpath" >"$tmp/head" 2>/dev/null \
            || die "preship-verified-head: cannot read $cpath at HEAD in $tree"
        h_rc=0
        python3 -I "$hunks" "$tmp/merged" "$tmp/head" "$vh40" "$T" >"$tmp/reason" 2>/dev/null || h_rc=$?
        reason=""
        IFS= read -r reason <"$tmp/reason" || true
        case "$h_rc:${reason:+set}" in
            0:*)   : ;;
            3:set) refuse append-only "$cpath: $reason" ;;
            *)     refuse append-only "$cpath: checker failed (exit $h_rc)" ;;
        esac
    done

    # (f) a merge gate in mr.md is head-tied evidence: forward cannot carry it.
    gate_rc=0
    merge_forward_gate "$issue_dir" || gate_rc=$?
    case "$gate_rc" in
        0) refuse "merge gate" "$issue_dir/mr.md line $MF_GATE_LINE mentions a merge gate; head-tied evidence needs /devagent:preship" ;;
        1) : ;;
        *) refuse "merge gate" "cannot read $issue_dir/mr.md; cannot tell whether the MR carries a merge gate" ;;
    esac

    # Success: one transaction, one log line.
    if [ "${#MF_CONFLICTED[@]}" -eq 0 ]; then
        how="no conflict"
    else
        how="both sides kept in ${MF_CONFLICTED[0]}"
        for p in "${MF_CONFLICTED[@]:1}"; do how+=", $p"; done
    fi
    msg="verified_head $head from ${vh40:0:7} (git's merge of ${T:0:7}; $how)"
    state_ctx_set_many "$project" "$issue_arg" str verified_head "$head" str verified_by forward
    log_append "$issue_dir" forward "$msg"
    echo "forward: $msg"
    # Clears rule 14 (merged forward: this is its light remedy) and rule 11 only when
    # it names this head; never 10, 15, a preship: stop or forward's own rule 17.
    clear_mergemr_stop forward "^(mergemr rule 14: |mergemr rule 11: PR head ${head:0:7} was not verified; )"
    exit 0
fi

# ---- record ------------------------------------------------------------------
pin="$(state_ctx_get "$project" preship_pin_head "$issue_arg")" \
    || die "preship-verified-head: could not read preship_pin_head from state for $issue_arg"
pin="${pin//$'\r'/}"
[ -n "$pin" ] || die "preship-verified-head: no pin recorded; run pin first"
[ "$pin" = "$head" ] \
    || die "preship-verified-head: HEAD moved during preship (${pin:0:7} → ${head:0:7}); nothing recorded"

state_ctx_set_many "$project" "$issue_arg" str verified_head "$head" str preship_pin_head "" str verified_by preship
log_append "$issue_dir" preship "verified_head $head"
echo "preship-verified-head: verified_head $head"

clear_mergemr_stop preship '^(mergemr rule (10|11|14|15): |mergemr rule 17: head [0-9a-f]{7} was recorded by forward |preship: )'
