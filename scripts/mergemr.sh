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

_die "mergemr: merging is not implemented yet; nothing was marked"
