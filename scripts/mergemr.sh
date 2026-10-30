#!/usr/bin/env bash
# scripts/mergemr.sh — step 20, the merge step (#885). Merges the issue's PR only when
# the project approves it (permissions.merge_mr is exactly true, read directly, never
# permission_gate: DA_YES and a TTY cannot open it) and only at the head the last
# passing preship recorded (verified_head). Never waits: every read is bounded and a
# run decides at once.
#
# It marks its own row BY NAME and ends one of four ways:
#   [x] merged, [-] ship was skipped   exit 0 (also writes last_step/last_step_name)
#   [?] waiting                        exit 0; prints `mergemr: waiting (<rule>): <reason>`
#                                      and logs `waiting (<rule>): <reason>` only when it
#                                      differs from the last `mergemr:` log line
#   [!] a stop                         exit 1; STUCK through checklist-stuck.sh --name
#                                      mergemr, reason `mergemr rule <N>: <text>` (preship's
#                                      record clears rules 10, 11, 14 and 15 by that prefix)
# next.sh reads the glyph after exit 0. The decision order (first match wins) and every
# message are in commands/mergemr.md.
#
# Knobs: DEVAGENT_MERGEMR_READ_SECS (20; the PR read, the re-read after a merge, each
# dependency read), DEVAGENT_MERGEMR_MERGE_SECS (30; the merge call and the auto-merge
# disable), DEVAGENT_CI_GRACE_SECS (120; #782's no-checks grace).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/transition.sh"
. "$DEVAGENT_ROOT/scripts/lib/merge-marker.sh"
. "$DEVAGENT_ROOT/scripts/lib/depends.sh"
. "$DEVAGENT_ROOT/scripts/lib/ci.sh"

_die() { printf '%s\n' "$*" >&2; exit 1; }

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

# Config first, every run, whatever merge_mr says: a typo surfaces before the project
# turns merging on (fail closed, Issue-780). Both are setter-globals: call bare.
merge_checks_resolve "$project"
merge_method_resolve "$project"
merge_ok=0
_mm="$(config_get_project_field "$project" permissions.merge_mr 2>/dev/null || true)"
[ "${_mm//$'\r'/}" = true ] && merge_ok=1

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue — pin/state only, else die.
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi
issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"
cl="$issue_dir/checklist.md"

self_num="$(checklist_step_num_by_name "$cl" mergemr)" || _die "mergemr: no mergemr row in $cl"
ship_g="$(checklist_step_state_by_name "$cl" ship 2>/dev/null || true)"
case "$ship_g" in
    x|-) ;;
    *) _die "mergemr: ship is [$ship_g]; run /devagent:ship first" ;;
esac

backend="$(config_get_project_field "$project" code_source.backend 2>/dev/null || true)"
backend="${backend//$'\r'/}"
code_sh="${DEVAGENT_CODE_BACKEND_DIR:-$(plugin_root)/scripts/code}/${backend:-(none)}.sh"

# ---- how a run ends ----------------------------------------------------------------

# _done <log message>: [x], last_step, log. The caller fires on_merge and exits.
_done() {
    state_ctx_set_many "$project" "$issue_arg" str last_step "$self_num" str last_step_name mergemr
    checklist_mark_by_name "$issue_dir/checklist.md" mergemr x
    log_append "$issue_dir" mergemr "$1"
    echo "mergemr: $1"
}

# _last_logged: the message of the last `mergemr:` line in the checklist Log.
_last_logged() {
    awk '/^## Log/ { p = 1; next } /^## / { p = 0 } p' "$cl" \
        | grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  mergemr: ' \
        | tail -n 1 | sed -E 's/^- [0-9-]+ [0-9:]+  mergemr: //' || true
}

# _wait <rule> <reason> [log message]: [?], print, log once per change; exit 0. The
# log message defaults to `waiting (<rule>): <reason>`.
_wait() {
    local line="waiting ($1): $2" msg="${3:-waiting ($1): $2}"
    checklist_mark_by_name "$issue_dir/checklist.md" mergemr "?"
    echo "mergemr: $line"
    [ "$(_last_logged)" = "$msg" ] || log_append "$issue_dir" mergemr "$msg"
    exit 0
}

# _stop <rule> <text>: [!] and STUCK (`mergemr rule <N>: <text>`); exit 1.
_stop() {
    local reason="mergemr rule $1: $2"
    echo "$reason" >&2
    bash "$DEVAGENT_ROOT/scripts/checklist-stuck.sh" --name mergemr "$issue_dir" "$reason" || true
    exit 1
}

# _on_merge: fire on_merge once per revision. The marker is sync's (A0.1): skip when
# it is present; merge_marker_fire writes it only for an outcome with nothing left
# to retry, so a gated or failed fire is retried by the next mergemr or sync run.
_on_merge() {
    merge_marker_present "$cl" && return 0
    merge_marker_fire mergemr "$project" "$issue_arg" "$issue_dir" \
        " — no merge marker written; the next mergemr or sync run retries it"
}

# _merged <log message>: [x], on_merge, the next-step hint; exit 0.
_merged() {
    _done "$1"
    _on_merge
    checklist_print_next_hint "$cl"
    exit 0
}

# _call <knob> <default> <cmd> [args...]: one bounded backend call, stdin from
# /dev/null. Sets _OUT (stdout), _RC (exit code) and _ERR (a bare reason: `timed out
# after Ns`, the last non-blank stderr line, or `<cmd> exited <rc>`). Never fails.
_call() {
    local knob="$1" def="$2" errf errs; shift 2
    _OUT=""; _RC=0; _ERR=""
    if ! command -v timeout >/dev/null 2>&1; then
        _RC=127; _ERR="timeout(1) not on PATH"; return 0
    fi
    _ci_secs "$knob" "$def"
    errf="$(mktemp 2>/dev/null)" || errf=/dev/null
    _OUT="$(bounded_call "$_CI_SECS" "$@" </dev/null 2>"$errf")" || _RC=$?
    _OUT="${_OUT//$'\r'/}"
    case "$_RC" in
        0) ;;
        124|137) _ERR="timed out after ${_CI_SECS}s" ;;
        *)
            errs="$( { grep -v '^[[:space:]]*$' "$errf" 2>/dev/null || true; } | tr -d '\r')"
            _ERR="${errs##*$'\n'}"
            [ -n "$_ERR" ] || _ERR="$(basename "$1") exited $_RC" ;;
    esac
    [ "$errf" = /dev/null ] || rm -f "$errf"
    return 0
}

R4_TEXT="PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"

# ---- rules 1-2: whatever the backend -------------------------------------------------

if [ "$ship_g" = - ]; then                                                   # rule 1
    state_ctx_set_many "$project" "$issue_arg" str last_step "$self_num" str last_step_name mergemr
    checklist_mark_by_name "$issue_dir/checklist.md" mergemr -
    log_append "$issue_dir" mergemr "skipped: ship was skipped (no PR)"
    echo "mergemr: skipped: ship was skipped (no PR)"
    checklist_print_next_hint "$cl"
    exit 0
fi

mr_url="$(state_ctx_get "$project" mr_url "$issue_arg" 2>/dev/null || true)"
mr_url="${mr_url//$'\r'/}"
if [ -z "$mr_url" ]; then                                                    # rule 2
    if [ "$merge_ok" = 1 ]; then
        _stop 2 "no PR URL recorded for this issue; merge the PR by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark"
    fi
    _wait 2 "no PR URL recorded for this issue; merge the PR by hand, then mark this step [x] with /devagent:checklist-mark"
fi

# ---- other backends: one mr-state read, whatever merge_mr says -----------------------
# Merging is GitHub only (#885). Decided by the code backend's name, so a non-github
# backend never reaches ci_read_view. Exit 78 (not implemented) or 2 (unknown verb)
# means the backend cannot tell; any other failure is a read that decided nothing.
if [ "$backend" != github ]; then
    if [ ! -x "$code_sh" ]; then
        _wait read "could not read PR $mr_url: ${backend:-(none)}.sh not found or not executable"
    fi
    _call DEVAGENT_MERGEMR_READ_SECS 20 "$code_sh" mr-state "$mr_url"
    case "$_RC" in
        0) ;;
        78|2) _wait read "cannot read PR state on ${backend:-(none)}; merge by hand, then mark this step [x] with /devagent:checklist-mark" ;;
        *) _wait read "could not read PR $mr_url: $_ERR" ;;
    esac
    _st="$(printf '%s' "$_OUT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$_st" in
        merged) _merged "PR $mr_url merged (merge commit -)" ;;
        closed) _stop 4 "$R4_TEXT" ;;
        open)   _wait 8 "waiting for merge (merge step supports github only)" ;;
        *)      _wait read "could not read PR $mr_url: unrecognised mr-state output '$_st'" ;;
    esac
fi

# ---- the PR read -----------------------------------------------------------------

ci_read_view "$project" "$issue_arg" "$mr_url"
[ "$MV_OK" = 1 ] || _wait read "could not read PR $mr_url: ${MV_ERR:-${_CI_REASON:-unknown error}}"
ci_report "$issue_dir"

# ---- rules 3-8: whatever merge_mr says ------------------------------------------------

[ "$CI_RESULT" != merged ] || _merged "PR $mr_url merged (merge commit $MV_MERGECOMMIT)"   # rule 3
[ "$CI_RESULT" != closed ] || _stop 4 "$R4_TEXT"                                         # rule 4
[ "$MV_DRAFT" != true ] || _wait 5 "draft PR"                                            # rule 5

default_base="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
default_base="$(printf '%s' "${default_base//$'\r'/}" | sed 's|^[^/]*/||')"
[ -n "$default_base" ] || default_base=main
[ "$MV_BASE" = "$default_base" ] || _wait 6 "stacked on $MV_BASE"                       # rule 6

# rule 7. Each dependency: the first source that answers decides — (1) its recorded
# PR (mr-state), (2) its linked PRs (one issue-mrs call per tracker repo), (3) its
# tracker issue (state-class). Any failed read waits at once: it decides nothing.
_deps_check() {
    local deps dep url st repo n line cls why
    local -a order=() unsat=()
    local -A found=() nums=() dep_of=() batch=()
    deps="$(depends_list "$project" "$issue_arg")"
    for dep in $deps; do
        order+=("$dep")
        url="$(state_issue_get "$project" "$dep" mr_url 2>/dev/null || true)"
        url="${url//$'\r'/}"
        if [ -n "$url" ]; then
            _call DEVAGENT_MERGEMR_READ_SECS 20 "$code_sh" mr-state "$url"
            [ "$_RC" -eq 0 ] || _wait 7 "could not read $dep PR state: $_ERR"
            st="$(printf '%s' "$_OUT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
            case "$st" in
                merged) found[$dep]="" ;;
                open)   found[$dep]="PR open" ;;
                closed) found[$dep]="PR closed unmerged" ;;
                *) _wait 7 "could not read $dep PR state: unrecognised mr-state output '$st'" ;;
            esac
            continue
        fi
        transition_route "$project" "$dep"
        if [ -n "$TR_REPO" ] && [[ "$TR_NUM" =~ ^[0-9]+$ ]]; then
            nums[$TR_REPO]+=" $TR_NUM"
            batch[$TR_REPO]+=", $dep"
            dep_of["$TR_REPO#$TR_NUM"]="$dep"
        fi
    done
    for repo in "${!nums[@]}"; do
        # shellcheck disable=SC2086  # the numbers are digits only
        _call DEVAGENT_MERGEMR_READ_SECS 20 "$code_sh" issue-mrs "$repo" ${nums[$repo]}
        [ "$_RC" -eq 0 ] || _wait 7 "could not read ${batch[$repo]#, } linked PRs: $_ERR"
        while IFS=$'\t' read -r line n st; do
            if [ "$line" != issue ] || [ -z "${dep_of["$repo#$n"]:-}" ]; then continue; fi
            case "$st" in
                merged)     found[${dep_of["$repo#$n"]}]="" ;;
                open|draft) found[${dep_of["$repo#$n"]}]="PR open" ;;
            esac
        done <<<"$_OUT"
    done
    for dep in "${order[@]+"${order[@]}"}"; do
        [ -z "${found[$dep]+set}" ] || continue
        transition_route "$project" "$dep"
        if [ -z "$TR_BACKEND" ] || [ -z "$TR_REPO" ]; then
            _wait 7 "could not read $dep tracker state: no issue tracker configured"
        fi
        _call DEVAGENT_MERGEMR_READ_SECS 20 "$(transition_backend_sh "$TR_BACKEND")" state-class "$TR_REPO" "$TR_NUM"
        [ "$_RC" -eq 0 ] || _wait 7 "could not read $dep tracker state: $_ERR"
        IFS=$'\t' read -r cls why <<<"$_OUT"
        case "$cls" in
            done) found[$dep]="" ;;
            open|in_progress) found[$dep]="open, no PR" ;;
            ?*) [ "${why:--}" != - ] || why="$cls"; found[$dep]="closed: $why" ;;
            *) _wait 7 "could not read $dep tracker state: unrecognised state-class output" ;;
        esac
    done
    for dep in "${order[@]+"${order[@]}"}"; do
        [ -z "${found[$dep]}" ] || unsat+=("$dep (${found[$dep]})")
    done
    if [ "${#unsat[@]}" -gt 0 ]; then
        line="$(printf '; %s' "${unsat[@]}")"
        _wait 7 "waiting for ${line#; }"
    fi
    return 0
}
_deps_check

[ "$merge_ok" = 1 ] || _wait 8 "waiting for merge ($CI_RESULT, $MV_MERGEABLE/$MV_MERGESTATE)"   # rule 8

# ---- rules 9-18: only when the step would merge ----------------------------------------

# rule 9, the trust boundary: the PR must be on ship's target repo (config_code_target_repo,
# ship's own rule), compared case-insensitively. An empty target is a config fault.
_rest="${mr_url#*://}"; _rest="${_rest#*/}"
IFS=/ read -r _owner _name _ <<<"$_rest"
pr_repo="$_owner/$_name"
config_code_target_repo "$project"
if [ -z "$CODE_TARGET_REPO" ]; then
    _stop 9 "no code_source.upstream configured for '$project'; set it, then run /devagent:unstuck"
fi
if [ "${pr_repo,,}" != "${CODE_TARGET_REPO,,}" ]; then
    _stop 9 "PR is not on $CODE_TARGET_REPO; it is on $pr_repo. Fix mr_url or code_source, then run /devagent:unstuck"
fi

verified_head="$(state_ctx_get "$project" verified_head "$issue_arg" 2>/dev/null || true)"
verified_head="${verified_head//$'\r'/}"
[ -n "$verified_head" ] || _stop 10 "no verified head for this PR; run /devagent:preship"   # rule 10

if [ "$CI_HEAD" != "$verified_head" ]; then                                   # rule 11
    # An auto-merge enabled earlier survives a push (A0.4): turn it off, or GitHub could
    # merge the unverified head on its own.
    _note=""
    if [ "$MV_AUTOMERGE" = on ]; then
        _call DEVAGENT_MERGEMR_MERGE_SECS 30 "$code_sh" merge-mr "$mr_url" --disable-auto
        if [ "$_RC" -eq 0 ]; then _note=" (auto-merge disabled)"
        else _note=" (could not disable auto-merge: $_ERR; disable it on the forge)"
        fi
    fi
    _stop 11 "PR head ${CI_HEAD:0:7} was not verified; run /devagent:preship on it$_note"
fi

# rule 12: the PR's live state, not the log — a queue that ejects it, or a cancelled
# auto-merge, falls through to the rules below.
if [ "$MV_AUTOMERGE" = on ] || [ "$MV_QUEUE" = true ]; then
    _wait 12 "merge accepted; waiting ($CI_RESULT, $MV_MERGEABLE/$MV_MERGESTATE)"
fi
if [ "$MV_MERGEABLE" = UNKNOWN ] || [ "$MV_MERGESTATE" = UNKNOWN ]; then      # rule 13
    _wait 13 "mergeability not computed yet"
fi
[ "$MV_MERGEABLE" != CONFLICTING ] \
    || _stop 14 "conflict with $MV_BASE; merge it forward, run scripts/rebaseline.sh, re-run scripts/run-suite.sh and scripts/evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"   # rule 14

# rules 15-17: #782's verdict, unchanged. ci_gate does not apply here: merging is a
# stronger act than reporting.
ci_verdict
case "$CI_VERDICT" in
    red)                                                                      # rule 15
        _stop 15 "$CI_LINE; fix it, re-run scripts/run-suite.sh and scripts/evidence-stamp.sh (review.md 6a), push, then run /devagent:preship" ;;
    hold)                                                                     # rule 16
        [ "$CI_RESULT" != none ] || _wait 16 "checks not reported yet (grace ${_CI_SECS}s)"
        _wait 16 "$CI_LINE" ;;
    proceed) ;;
    *) _wait 16 "unexpected CI verdict '$CI_VERDICT'" ;;
esac
if [ "$CI_RESULT" = none ] && [ "$MERGE_CHECKS" = required ]; then           # rule 17
    _stop 17 "no CI checks on head commit; set merge_checks = \"if-present\" to merge without CI, then run /devagent:unstuck"
fi
case "$MV_MERGESTATE" in                                                      # rule 18
    CLEAN|HAS_HOOKS) ;;
    *) _stop 18 "blocked by a forge rule ($MV_MERGESTATE); resolve it on the forge, then run /devagent:unstuck" ;;
esac

# ---- rule 19: the merge -------------------------------------------------------------------

# _squash_body: one `Closes <ref>` line per closing reference (`#N` on the PR's own repo,
# case-insensitively, else `owner/name#N`) — the PR's own closingIssuesReferences and
# nothing else, so `Related: #N` closes nothing; then the distinct Signed-off-by lines,
# then the Co-authored-by lines unless include_coauthor = false. One blank line between
# the two blocks only when both are non-empty. May be empty.
_squash_body() {
    local c t closes="" trailers="" coauthor
    local -a sob=() co=()
    local -A seen=()
    for c in "${MV_CLOSES[@]+"${MV_CLOSES[@]}"}"; do     # owner/name#n (ci_read_view)
        t="${c%#*}"
        if [ "${t,,}" = "${pr_repo,,}" ]; then
            closes+=$'\n'"Closes #${c##*#}"
        else
            closes+=$'\n'"Closes $c"
        fi
    done
    coauthor="$(config_get_project_field "$project" include_coauthor 2>/dev/null || echo true)"
    coauthor="${coauthor//$'\r'/}"
    for t in "${MV_TRAILERS[@]+"${MV_TRAILERS[@]}"}"; do
        [ -z "${seen[$t]:-}" ] || continue
        seen[$t]=1
        case "${t,,}" in
            signed-off-by:*)  sob+=("$t") ;;
            co-authored-by:*) co+=("$t") ;;
        esac
    done
    [ "$coauthor" != false ] || co=()
    for t in "${sob[@]+"${sob[@]}"}" "${co[@]+"${co[@]}"}"; do trailers+=$'\n'"$t"; done
    closes="${closes#$'\n'}"; trailers="${trailers#$'\n'}"
    if [ -n "$closes" ] && [ -n "$trailers" ]; then
        printf '%s\n\n%s' "$closes" "$trailers"
    else
        printf '%s%s' "$closes" "$trailers"
    fi
}

if [ "$MERGE_METHOD" = squash ] && (( 10#$MV_COMMITS_TOTAL > 10#$MV_COMMITS_READ )); then
    _stop 19 "PR has $MV_COMMITS_TOTAL commits but $MV_COMMITS_READ were read; the squash trailers would be incomplete. Merge it by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark"
fi
merge_args=(merge-mr "$mr_url" --method "$MERGE_METHOD" --match-head-commit "$verified_head")
if [ "$MERGE_METHOD" = squash ]; then
    # --body is passed even when empty: gh would otherwise fill in its own default body.
    merge_args+=(--subject "$MV_TITLE (#$MV_NUMBER)" --body "$(_squash_body)")
fi
_call DEVAGENT_MERGEMR_MERGE_SECS 30 "$code_sh" "${merge_args[@]}"
# A bound that killed a call GitHub had already accepted is seen through rule 3 on the
# run after /devagent:unstuck.
[ "$_RC" -eq 0 ] || _stop 19 "merge call failed: $_ERR; then run /devagent:unstuck"

ci_read_view "$project" "$issue_arg" "$mr_url"
[ "$MV_OK" = 1 ] || _wait 19 "could not read PR after merge: ${MV_ERR:-${_CI_REASON:-unknown error}}"
case "$CI_RESULT" in
    merged) _merged "merged $mr_url by $MERGE_METHOD at $verified_head → $MV_MERGECOMMIT" ;;
    closed) _stop 4 "$R4_TEXT" ;;
esac
# Still open: a merge queue took it, or the forge turned it into an auto-merge. Rule 12
# stops a second merge call while it is pending.
_wait 19 "merge accepted; PR still open (merge queue or auto-merge)" \
    "merge accepted $mr_url by $MERGE_METHOD at $verified_head; PR still open"
