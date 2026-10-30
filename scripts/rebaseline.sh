#!/usr/bin/env bash
# scripts/rebaseline.sh — re-key the issue's baseline_sha after a merge-forward
# (#885 A0.5). Usage: rebaseline.sh <project> [issue]
#
# After the default base is merged INTO the issue branch (a merge-forward, the
# remedy for a conflicting or stale PR), baseline_sha still names the old fork
# point, so every `<baseline_sha>..HEAD` diff (review, redmr, preship, the
# evidence stamp) would also show the base's own commits. This sets baseline_sha
# to the merge base of default_baseline and HEAD — the point the branch now
# diverges from — and refuses every shape where that point is not well defined:
#   * HEAD is not on the issue branch (register Issue-69): the merge base would
#     describe some other branch;
#   * more than one merge base (a criss-cross history, research U7): git has no
#     single answer and picking one silently would mis-scope every diff;
#   * the new base does not contain the recorded one: the baseline never moves
#     backwards (a stale local base ref, older than the fork point, yields an
#     older merge base — the fetch below is best-effort, so this can happen).
# Unchanged prints and writes nothing else. A change is written with
# state_ctx_set_many, printed and logged (`rebaseline: baseline_sha <old7> →
# <new7>`). Every refusal exits 1 with state and checklist untouched.
#
# The issue resolves as mergetoall's does (pin or state, never a scan, #240); the
# tree is the issue's (active_tree_resolve, register Issue-590/595). The fetch of
# default_baseline's remote is bounded (DEVAGENT_REBASELINE_FETCH_SECS, default
# 20, #660) and best-effort: a failure warns and the last-known ref is used.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
# ci.sh: _ci_secs (the knob validator); it sources upstream.sh (_upstream_bounded).
. "$DEVAGENT_ROOT/scripts/lib/ci.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "rebaseline: project required"
config_is_project "$project" || die "rebaseline: unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: never act on a scan-GUESSED issue — pin/state only, else die.
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "rebaseline: no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "rebaseline: issue_dir not set or missing"
branch="$(state_ctx_get "$project" branch "$issue_arg" 2>/dev/null || true)"
[ -n "$branch" ] || die "rebaseline: no branch in state for $issue_arg"

active_tree_resolve "$project" "$issue_arg"     # setter-globals; never $( … )
tree="$ACTIVE_TREE_DIR"
g() { "$DEVAGENT_GIT" -C "$tree" "$@"; }

# Off-branch refusal first: nothing is fetched or written for a wrong branch.
# The full ref, stripped by hand (`--short` prints heads/<b> when a tag shares
# the name; run-suite.sh #660).
ref_rc=0
head_ref="$(g symbolic-ref --quiet HEAD 2>/dev/null)" || ref_rc=$?
case "$ref_rc:$head_ref" in
    0:refs/heads/?*) on="${head_ref#refs/heads/}" ;;
    1:*) die "rebaseline: HEAD is detached at $(g rev-parse --short HEAD 2>/dev/null || echo '?'), not on the issue branch $branch (in $tree)" ;;
    *)   die "rebaseline: could not read which branch HEAD is on in $tree (git symbolic-ref exited $ref_rc)" ;;
esac
[ "$on" = "$branch" ] || die "rebaseline: HEAD is on $on, not the issue branch $branch (in $tree)"

base_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
base_ref="${base_ref//$'\r'/}"
[ -n "$base_ref" ] || die "rebaseline: no default_baseline configured for '$project'"

# Best-effort, bounded refresh of the base ref: only the one branch, into its
# remote-tracking ref, no FETCH_HEAD (as upstream_branch_tip, #660). A base
# whose prefix is not a configured remote is a local ref: nothing to fetch.
case "$base_ref" in
    */*)
        remote="${base_ref%%/*}" rbranch="${base_ref#*/}"
        if upstream_remote_configured "$tree" "$remote"; then
            _ci_secs DEVAGENT_REBASELINE_FETCH_SECS 20
            secs="$_CI_SECS"
            if ! command -v timeout >/dev/null 2>&1; then
                warn "rebaseline: could not fetch '$remote' (timeout(1) not on PATH, so the fetch cannot be bounded); using the last-known $base_ref"
            else
                f_rc=0
                _upstream_bounded "$tree" "$secs" fetch --quiet --no-write-fetch-head \
                    "$remote" "+refs/heads/$rbranch:refs/remotes/$remote/$rbranch" </dev/null >/dev/null || f_rc=$?
                case "$f_rc" in
                    0) : ;;
                    124|137) warn "rebaseline: could not fetch '$remote' (timed out after ${secs}s); using the last-known $base_ref" ;;
                    *)       warn "rebaseline: could not fetch '$remote' (git fetch exited $f_rc); using the last-known $base_ref" ;;
                esac
            fi
        fi ;;
esac

g rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null \
    || die "rebaseline: cannot resolve $base_ref in $tree"

mb_rc=0
bases="$(g merge-base --all "$base_ref" HEAD 2>/dev/null)" || mb_rc=$?
case "$mb_rc" in
    0|1) : ;;    # 1 = no common ancestor: counted as 0 below
    *)   die "rebaseline: git merge-base --all $base_ref HEAD failed in $tree (exit $mb_rc)" ;;
esac
n="$(printf '%s\n' "$bases" | grep -c . || true)"
[ "$n" -eq 1 ] \
    || die "rebaseline: $n merge bases between $base_ref and HEAD; refusing to pick one — set baseline_sha by hand"
new="$bases"

old="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
old="${old//$'\r'/}"
old_full=""
if [ -n "$old" ]; then
    old_full="$(g rev-parse --verify --quiet "${old}^{commit}" 2>/dev/null)" \
        || die "rebaseline: the recorded baseline_sha '$old' is not a commit in $tree; refusing — set baseline_sha by hand"
fi

if [ "$old_full" = "$new" ]; then
    echo "rebaseline: baseline_sha unchanged (${new:0:7})"
    exit 0
fi

# Never backwards: the new base must contain the recorded one.
if [ -n "$old_full" ]; then
    anc_rc=0
    g merge-base --is-ancestor "$old_full" "$new" 2>/dev/null || anc_rc=$?
    case "$anc_rc" in
        0) : ;;
        1) die "rebaseline: new base ${new:0:7} does not contain the recorded baseline ${old_full:0:7}; refusing to move it backwards" ;;
        *) die "rebaseline: could not compare the recorded baseline ${old_full:0:7} with ${new:0:7} (git merge-base --is-ancestor exited $anc_rc); refusing" ;;
    esac
fi

old7="${old_full:0:7}"
[ -n "$old7" ] || old7="(none)"
state_ctx_set_many "$project" "$issue_arg" str baseline_sha "$new"
msg="baseline_sha $old7 → ${new:0:7}"
echo "rebaseline: $msg"
log_append "$issue_dir" rebaseline "$msg"
