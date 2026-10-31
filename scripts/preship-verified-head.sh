#!/usr/bin/env bash
# scripts/preship-verified-head.sh — record the head a passing preship verified
# (#885). Usage: preship-verified-head.sh (pin|record) <project> [issue]
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
#           else writes `verified_head`, clears the pin, logs
#           `preship: verified_head <sha40>`.
# Both verbs refuse unless the tree's HEAD is the issue branch (register
# Issue-69): a head on another branch verifies nothing about the PR.
#
# Clearing a stop. A post-ship preship is the remedy mergemr's rules 10 (no
# verified head), 11 (head not verified), 14 (conflict, merged forward) and 15
# (red CI, fixed) name, and the remedy for a FAILED post-ship preship that
# stopped the mergemr row. `record` clears that stop — and only that one — when
# ALL hold: ship is [x] (in the active revision block), the mergemr row is [!],
# STUCK's `Step:` names mergemr, its `Reason:` starts `mergemr rule 10|11|14|15: `
# or `preship: `, and the [!] row checklist-unstuck.sh will flip (it is
# line-based, Issue-587: the active block's first [!]) IS mergemr. It then runs
# `checklist-unstuck.sh --pending` and logs `preship: cleared mergemr stop
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
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_GIT:=git}"

usage() {
    echo "usage: preship-verified-head.sh (pin|record) <project> [issue]" >&2
    exit 2
}

verb="${1:-}"
case "$verb" in pin|record) : ;; *) usage ;; esac

project="${2:-}"
[ -n "$project" ] || die "preship-verified-head: project required"
config_is_project "$project" || die "preship-verified-head: unknown project '$project'"

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

# ---- record ------------------------------------------------------------------
pin="$(state_ctx_get "$project" preship_pin_head "$issue_arg")" \
    || die "preship-verified-head: could not read preship_pin_head from state for $issue_arg"
pin="${pin//$'\r'/}"
[ -n "$pin" ] || die "preship-verified-head: no pin recorded; run pin first"
[ "$pin" = "$head" ] \
    || die "preship-verified-head: HEAD moved during preship (${pin:0:7} → ${head:0:7}); nothing recorded"

state_ctx_set_many "$project" "$issue_arg" str verified_head "$head" str preship_pin_head ""
log_append "$issue_dir" preship "verified_head $head"
echo "preship-verified-head: verified_head $head"

# ---- clearing a mergemr stop a fresh preship remedies --------------------------
cl="$issue_dir/checklist.md"
stuck="$issue_dir/STUCK"
[ -f "$cl" ] && [ -f "$stuck" ] || exit 0
ship_g="$(checklist_step_state_by_name "$cl" ship 2>/dev/null || true)"
mm_g="$(checklist_step_state_by_name "$cl" mergemr 2>/dev/null || true)"
[ "$ship_g" = x ] && [ "$mm_g" = '!' ] || exit 0

stuck_step="$(sed -n 's/^Step:[[:space:]]*//p' "$stuck" | head -n 1)"
stuck_step="${stuck_step//$'\r'/}"
reason="$(sed -n 's/^Reason:[[:space:]]*//p' "$stuck" | head -n 1)"
reason="${reason//$'\r'/}"
[ "${stuck_step##* }" = mergemr ] || exit 0
clear_re='^(mergemr rule (10|11|14|15): |preship: )'
[[ "$reason" =~ $clear_re ]] || exit 0

# checklist-unstuck.sh flips the active block's FIRST [!] by line (#587); clear
# only when that row is mergemr, so no other stop is flipped in its place.
found="$(checklist_find_glyph_line "$cl" '!')"
row="${found%%:*}"
at=""
[ -n "$row" ] && at="$(checklist_step_name_at_line "$cl" "$row" 2>/dev/null || true)"
if [ "$at" != mergemr ]; then
    warn "preship-verified-head: the first [!] row is '${at:-?}', not mergemr; the mergemr stop is left for /devagent:unstuck"
    exit 0
fi

bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$issue_dir"
msg="cleared mergemr stop (${reason:0:60})"
log_append "$issue_dir" preship "$msg"
echo "preship: $msg"
