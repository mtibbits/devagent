#!/usr/bin/env bash
# scripts/mergemr.sh — step 20, the merge step (#885). Merges the issue's PR only when
# the project approves it (permissions.merge_mr is exactly true, read directly, never
# permission_gate: DA_YES and a TTY cannot open it) and only at the head the last
# passing preship recorded (verified_head). Never waits: every read is bounded and a
# run decides at once. Rule 14 (#1125) also makes one fetch of default_baseline's
# branch, bounded by DEVAGENT_MERGEMR_FETCH_SECS, and runs a local `git merge-tree`
# that writes loose objects into the issue tree, to name the conflicted paths.
# With `required_checks` set (#1097) it merges only when each of those checks is
# `success` at that head (rules 15 and 16), and rules 8 and 12 report their states. On
# a code backend that cannot report checks it stops instead (rule 20, CI NOT CHECKED),
# whatever merge_mr says. A diff (baseline_sha..verified_head) that can change what
# those checks measure (a workflow file, a required_checks_paths path, a Git Bash tag
# line: lib/selfcert.sh) stops just before the merge call until the operator
# acknowledges it for that head (rule 21); rules 8 and 12 report it.
#
# It marks its own row BY NAME and ends one of four ways:
#   [x] merged, [-] ship was skipped   exit 0 (also writes last_step/last_step_name)
#   [?] waiting                        exit 0; prints `mergemr: waiting (<rule>): <reason>`
#                                      and logs `waiting (<rule>): <reason>` only when it
#                                      differs from the last `mergemr:` log line
#   [!] a stop                         exit 1; STUCK through checklist-stuck.sh --name
#                                      mergemr, reason `mergemr rule <N>: <text>` (preship's
#                                      record clears rules 10, 11, 14 and 15 and forward's
#                                      rule 17 by that prefix; forward clears rule 14, and
#                                      rule 11 when it names forward's head; rules 20 and
#                                      21 are the operator's, and neither clears them)
# next.sh reads the glyph after exit 0. The decision order (first match wins) and every
# message are in commands/mergemr.md.
#
# Knobs: DEVAGENT_MERGEMR_READ_SECS (20; the PR read, the re-read after a merge, each
# dependency read), DEVAGENT_MERGEMR_MERGE_SECS (30; the merge call and the auto-merge
# disable), DEVAGENT_MERGEMR_FETCH_SECS (20; rule 14's base fetch, #1125, and the
# self-certification scan's fetch of a commit its tree lacks, #1097),
# DEVAGENT_CI_GRACE_SECS (120; #782's no-checks grace, and #1097's for a required
# check that has not reported), DEVAGENT_CI_READ_SECS (20; ci_read's bound, for the
# required-checks read on a backend other than github, #1097).
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
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/merge-forward.sh"   # #1125: rule 14's light remedy, rule 17
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/selfcert.sh"        # #1097: rule 21's scan and acknowledgment
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/permission.sh"

_die() { printf '%s\n' "$*" >&2; exit 1; }

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

# Config first, every run, whatever merge_mr says: a typo surfaces before the project
# turns merging on (fail closed, Issue-780). Both are setter-globals: call bare.
merge_checks_resolve "$project"
merge_method_resolve "$project"
merge_forward_resolve "$project"     # #1125: MF_VERIFY, MF_APPEND_ONLY
required_checks_resolve "$project"   # #1097: REQUIRED_CHECKS, REQUIRED_CHECKS_PATHS

trust_entry_check "mergemr" "$project"
quarantine_guard "mergemr" "$project" "${2:-}"
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
# Read only after the entry check: under a trust policy in scope the policy
# alone decides (#713), and a read before the check would see config. Never
# merge_to_all_prs.
merge_ok=0
[ "$(permission_value "$project" merge_mr)" = true ] && merge_ok=1
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
        | tail -n 1 | sed -E 's/^- [0-9-]+ [0-9:]+  mergemr: //' | tr -d '\r' || true
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
# to retry, so a gated or failed fire is retried by a direct mergemr run or the next sync.
_on_merge() {
    merge_marker_present "$cl" && return 0
    merge_marker_fire mergemr "$project" "$issue_arg" "$issue_dir" \
        " — no merge marker written; a direct /devagent:mergemr run or the next sync retries it"
}

# _merged <log message>: [x], on_merge, the next-step hint; exit 0.
_merged() {
    _done "$1"
    _on_merge
    checklist_print_next_hint "$cl"
    exit 0
}

# _call <knob> <default> <cmd> [args...]: one bounded backend call (lib/ci.sh
# _ci_call: _CALL_OUT, _CALL_RC, _CALL_ERR), CRs stripped from _CALL_OUT.
_call() {
    _ci_call "$@"
    _CALL_OUT="${_CALL_OUT//$'\r'/}"
}

# _mr_state <url>: one bounded mr-state read (_call); _ST is its output, blanks
# stripped and lowercased.
_mr_state() {
    _call DEVAGENT_MERGEMR_READ_SECS 20 "$code_sh" mr-state "$1"
    _ST="$(printf '%s' "$_CALL_OUT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
}

# _rc_eval (#1097): after a CI read, judges the project's required checks by the lines
# the read kept (ci_required_eval: RC_OK, RC_BAD, RC_PENDING, RC_MISSING, RC_REPORT)
# and sets sfx, which ends rule 8's and rule 12's [?] line and rule 12's two stops;
# _selfcert_scan then adds the self-certification result to it. With no
# required_checks RC_OK is 1 and the rest, sfx included, is empty, so every rule reads
# as it did.
_rc_eval() {
    ci_required_eval ${REQUIRED_CHECKS[@]+"${REQUIRED_CHECKS[@]}"}
    sfx=""
    [ "${#REQUIRED_CHECKS[@]}" -eq 0 ] || sfx="; required checks at ${CI_HEAD:0:7}: $RC_REPORT"
}

# _selfcert_scan (#1097), after _rc_eval: whether the PR's diff, baseline_sha..
# verified_head, can change what its required checks measure (lib/selfcert.sh). It
# reports and never stops: rules 12 and 21 read SELFCERT_STATE, and sfx gains
# `; self-certifying: <paths>|none|unknown (<why>)`, so rule 8's [?] names the paths
# when the step does not merge. With no required_checks it reads nothing and sfx
# stays empty. Sets SELFCERT_BASE (baseline_sha) and SELFCERT_STATE:
#   none     nothing self-certifying changed
#   paths    SELFCERT_LIST names what did, and nobody acknowledged this head
#   acked    the same, acknowledged for this head (SELFCERT_ACK_REASON)
#   unknown  SELFCERT_WHY: no verified head, a PR head that is not the verified one
#            (the result would describe another commit), no baseline_sha, or
#            selfcert_paths's reason
# The commits are read in the recorded issue tree while it exists (probed in a
# subshell, as _r14 does: active_tree_resolve dies), else in source_dir, which keeps
# a removed worktree's commits. One that is not there gets one bounded fetch by id
# from default_baseline's remote first (DEVAGENT_MERGEMR_FETCH_SECS); the fetch
# writes no ref and no FETCH_HEAD, and a failed one leaves the scan to say `unknown`.
_selfcert_scan() {
    local head tree="" remote e rc=0
    local -a want=()
    SELFCERT_STATE=none SELFCERT_WHY="" SELFCERT_BASE="" SELFCERT_LIST=""
    SELFCERT_BAD_ENTRY="" SELFCERT_ACK_REASON=""
    [ "${#REQUIRED_CHECKS[@]}" -gt 0 ] || return 0
    head="$(state_ctx_get "$project" verified_head "$issue_arg" 2>/dev/null || true)"
    head="${head//$'\r'/}"
    SELFCERT_BASE="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
    SELFCERT_BASE="${SELFCERT_BASE//$'\r'/}"
    if [ -z "$head" ]; then
        SELFCERT_STATE=unknown SELFCERT_WHY="no verified head recorded"
    elif [ "$CI_HEAD" != "$head" ]; then
        SELFCERT_STATE=unknown SELFCERT_WHY="PR head ${CI_HEAD:0:7} is not the verified head ${head:0:7}"
    elif [ -z "$SELFCERT_BASE" ]; then
        SELFCERT_STATE=unknown SELFCERT_WHY="no baseline_sha recorded"
    else
        if (active_tree_resolve "$project" "$issue_arg") >/dev/null 2>&1; then
            active_tree_resolve "$project" "$issue_arg"     # setter-globals; never $( … )
            tree="$ACTIVE_TREE_DIR"
        else
            tree="$(config_get_project_field "$project" source_dir 2>/dev/null || true)"
            tree="${tree//$'\r'/}"
        fi
        if [ -n "$tree" ] && [ -d "$tree" ]; then
            for e in "$SELFCERT_BASE" "$head"; do
                [[ "$e" =~ ^[0-9a-f]{40,64}$ ]] || continue
                "$DEVAGENT_GIT" -C "$tree" cat-file -e "${e}^{commit}" 2>/dev/null || want+=("$e")
            done
        fi
        if [ "${#want[@]}" -gt 0 ]; then
            remote="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
            remote="${remote//$'\r'/}"
            case "$remote" in */*) remote="${remote%%/*}" ;; *) remote="" ;; esac
            if [ -n "$remote" ] && upstream_remote_configured "$tree" "$remote" \
                    && command -v timeout >/dev/null 2>&1; then
                _ci_secs DEVAGENT_MERGEMR_FETCH_SECS 20
                _upstream_bounded "$tree" "$_CI_SECS" fetch --quiet --no-write-fetch-head \
                    "$remote" "${want[@]}" </dev/null >/dev/null || true
            fi
        fi
        selfcert_paths "$tree" "$SELFCERT_BASE" "$head" \
            ${REQUIRED_CHECKS_PATHS[@]+"${REQUIRED_CHECKS_PATHS[@]}"} || rc=$?
        if [ "$rc" -ne 0 ]; then SELFCERT_STATE=unknown
        elif [ "${#SELFCERT_PATHS[@]}" -eq 0 ]; then SELFCERT_STATE=none
        elif selfcert_ack "$issue_dir" "$head"; then SELFCERT_STATE=acked
        else SELFCERT_STATE=paths
        fi
    fi
    case "$SELFCERT_STATE" in
        none)    sfx+="; self-certifying: none" ;;
        paths)   sfx+="; self-certifying: $SELFCERT_LIST" ;;
        acked)   sfx+="; self-certifying: $SELFCERT_LIST (acknowledged)" ;;
        unknown) sfx+="; self-certifying: unknown ($SELFCERT_WHY)" ;;
    esac
}

# _logged_since_head <message>: rc 0 when a `mergemr:` log line written since the head
# was last recorded (the `verified_head` line preship's record and forward log) is
# <message>. It reads every such line, not the last one, which a later wait or stop
# displaces.
_logged_since_head() {
    _MSG="$1" awk '
        /^## Log/ { p = 1; next } /^## / { p = 0 } !p { next }
        { sub(/\r$/, "") }
        /^- [0-9-]+ [0-9:]+  (preship|forward): verified_head / { hit = 0; next }
        { line = $0 }
        sub(/^- [0-9-]+ [0-9:]+  mergemr: /, "", line) && line == ENVIRON["_MSG"] { hit = 1 }
        END { exit !hit }' "$cl"
}

# _stop_unchecked <why> (#1097), rule 20: the project requires checks and this code
# backend cannot report them, so nothing here can say they succeeded. It applies
# whatever merge_mr says, and it is the operator's to clear: no preship record and no
# forward matches it. <why> is the bare reason (lib/ci.sh's _CI_REASON form). With
# `mark` the step cannot read the PR's state on this backend either, so no later run
# can see the hand merge: the remedy also marks the row, as rule 2's does.
_stop_unchecked() {
    local names how="then run /devagent:unstuck"
    [ "${2:-}" != mark ] || how+=" and mark this step [x] with /devagent:checklist-mark"
    names="$(printf ', %s' "${REQUIRED_CHECKS[@]}")"
    _stop 20 "CI NOT CHECKED: $1; required check ${names#, } cannot be read on this code backend; check it by hand, merge the PR by hand, $how"
}

R4_TEXT="PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"
# rule 15's remedy for a required check that is not successful (#1097).
R15_REQ_FIX="re-run the job on the forge and run /devagent:unstuck, or fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"

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
# With required_checks set (#1097) an open PR also gets one ci_read (mr-checks; the
# local backend is not asked): no step here may leave a PR waiting for a hand merge
# when nothing can say its required checks succeeded (rule 20). A backend that has the
# verb reports their states, and the self-certification scan's result, on rule 8's
# line, as the github path does.
if [ "$backend" != github ]; then
    if [ ! -x "$code_sh" ]; then
        _wait read "could not read PR $mr_url: ${backend:-(none)}.sh not found or not executable"
    fi
    _mr_state "$mr_url"
    case "$_CALL_RC" in
        0) ;;
        78|2)
            [ "${#REQUIRED_CHECKS[@]}" -eq 0 ] || _stop_unchecked "${backend:-(none)} has no mr-state" mark
            _wait read "cannot read PR state on ${backend:-(none)}; merge by hand, then mark this step [x] with /devagent:checklist-mark" ;;
        *) _wait read "could not read PR $mr_url: $_CALL_ERR" ;;
    esac
    case "$_ST" in
        merged) _merged "PR $mr_url merged (merge commit -)" ;;
        closed) _stop 4 "$R4_TEXT" ;;
        draft)  _wait 5 "draft PR" ;;
        open)
            [ "${#REQUIRED_CHECKS[@]}" -gt 0 ] || _wait 8 "waiting for merge (merge step supports github only)"
            ci_read "$project" "$issue_arg" "$mr_url"
            case "$CI_RESULT" in
                notchecked|notapplicable) _stop_unchecked "$_CI_REASON" ;;
                unknown) _wait read "could not read required checks on $mr_url: ${_CI_REASON:-unknown error}" ;;
            esac
            _rc_eval
            _selfcert_scan
            _wait 8 "waiting for merge (merge step supports github only)$sfx" ;;
        *)      _wait read "could not read PR $mr_url: unrecognised mr-state output '$_ST'" ;;
    esac
fi

# ---- the PR read -----------------------------------------------------------------

ci_read_view "$project" "$issue_arg" "$mr_url"
if [ "$MV_OK" != 1 ]; then
    # rule 20 (#1097): a backend script without mr-view (exit 78 or 2) cannot report
    # the required checks either. Any other failed read decided nothing: it waits.
    if [ "$CI_RESULT" = notchecked ] && [ "${#REQUIRED_CHECKS[@]}" -gt 0 ]; then
        _stop_unchecked "$_CI_REASON" mark
    fi
    _wait read "could not read PR $mr_url: ${MV_ERR:-${_CI_REASON:-unknown error}}"
fi
ci_report "$issue_dir"
_rc_eval

# ---- rules 3-8: whatever merge_mr says ------------------------------------------------

[ "$CI_RESULT" != merged ] || _merged "PR $mr_url merged (merge commit $MV_MERGECOMMIT)"   # rule 3
[ "$CI_RESULT" != closed ] || _stop 4 "$R4_TEXT"                                         # rule 4
[ "$MV_DRAFT" != true ] || _wait 5 "draft PR"                                            # rule 5

default_baseline_raw="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
default_baseline_raw="${default_baseline_raw//$'\r'/}"
default_base="$(printf '%s' "$default_baseline_raw" | sed 's|^[^/]*/||')"
[ -n "$default_base" ] || default_base=main
[ "$MV_BASE" = "$default_base" ] || _wait 6 "stacked on $MV_BASE"                       # rule 6

# rule 7. Each dependency: the first source that answers decides — (1) its recorded
# PR (mr-state), (2) its linked PRs (one issue-mrs call per tracker repo; a GitHub
# tracker only, as issue-mrs reads GitHub issue numbers), (3) its tracker issue
# (state-class). Any failed read waits at once: it decides nothing. A tracker with no
# state-class (exit 78 or 2) cannot answer (3): wait with the remedy, never merge.
_deps_check() {
    local deps dep url st repo n line cls why
    local -a order=() unsat=()
    local -A found=() nums=() dep_of=() batch=() r_be=() r_repo=() r_num=()
    deps="$(depends_list "$project" "$issue_arg")"
    for dep in $deps; do
        order+=("$dep")
        url="$(state_issue_get "$project" "$dep" mr_url 2>/dev/null || true)"
        url="${url//$'\r'/}"
        if [ -n "$url" ]; then
            _mr_state "$url"
            [ "$_CALL_RC" -eq 0 ] || _wait 7 "could not read $dep PR state: $_CALL_ERR"
            case "$_ST" in
                merged)     found[$dep]="" ;;
                open|draft) found[$dep]="PR open" ;;
                closed)     found[$dep]="PR closed unmerged" ;;
                *) _wait 7 "could not read $dep PR state: unrecognised mr-state output '$_ST'" ;;
            esac
            continue
        fi
        transition_route "$project" "$dep"
        r_be[$dep]="$TR_BACKEND" r_repo[$dep]="$TR_REPO" r_num[$dep]="$TR_NUM"
        if [ "$TR_BACKEND" = github ] && [ -n "$TR_REPO" ] && [[ "$TR_NUM" =~ ^[0-9]+$ ]]; then
            nums[$TR_REPO]+=" $TR_NUM"
            batch[$TR_REPO]+=", $dep"
            dep_of["$TR_REPO#$TR_NUM"]="$dep"
        fi
    done
    for repo in "${!nums[@]}"; do
        # shellcheck disable=SC2086  # the numbers are digits only
        _call DEVAGENT_MERGEMR_READ_SECS 20 "$code_sh" issue-mrs "$repo" ${nums[$repo]}
        [ "$_CALL_RC" -eq 0 ] || _wait 7 "could not read ${batch[$repo]#, } linked PRs: $_CALL_ERR"
        while IFS=$'\t' read -r line n st; do
            if [ "$line" != issue ] || [ -z "${dep_of["$repo#$n"]:-}" ]; then continue; fi
            case "$st" in
                merged)     found[${dep_of["$repo#$n"]}]="" ;;
                open|draft) found[${dep_of["$repo#$n"]}]="PR open" ;;
            esac
        done <<<"$_CALL_OUT"
    done
    for dep in "${order[@]+"${order[@]}"}"; do
        [ -z "${found[$dep]+set}" ] || continue
        if [ -z "${r_be[$dep]}" ] || [ -z "${r_repo[$dep]}" ]; then
            _wait 7 "could not read $dep tracker state: no issue tracker configured"
        fi
        _call DEVAGENT_MERGEMR_READ_SECS 20 "$(transition_backend_sh "${r_be[$dep]}")" state-class "${r_repo[$dep]}" "${r_num[$dep]}"
        case "$_CALL_RC" in
            0) ;;
            78|2) _wait 7 "cannot read $dep tracker state on ${r_be[$dep]}; merge order is yours: record its PR as [context.$dep].mr_url, or merge by hand, then mark this step [x] with /devagent:checklist-mark" ;;
            *) _wait 7 "could not read $dep tracker state: $_CALL_ERR" ;;
        esac
        IFS=$'\t' read -r cls why <<<"$_CALL_OUT"
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

# The self-certification scan (#1097), whatever merge_mr says: rule 8's [?] reports it,
# rule 12 and rule 21 act on it. Here rather than beside _rc_eval, so a PR that ends at
# rules 3-7 (merged, closed, a draft, stacked, waiting for a dependency) pays no git
# call and no fetch for a result nothing would print.
_selfcert_scan

[ "$merge_ok" = 1 ] || _wait 8 "waiting for merge ($CI_RESULT, $MV_MERGEABLE/$MV_MERGESTATE)$sfx"   # rule 8

# ---- rules 9-18, then 21: only when the step would merge ------------------------------

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
        if [ "$_CALL_RC" -eq 0 ]; then _note=" (auto-merge disabled)"
        else _note=" (could not disable auto-merge: $_CALL_ERR; disable it on the forge)"
        fi
    fi
    _stop 11 "PR head ${CI_HEAD:0:7} was not verified; run /devagent:preship on it (or push the verified head ${verified_head:0:7})$_note"
fi

# verified_by (#1125) counts as forward unless it reads as preship or empty (a legacy
# record): a read error or a garbled value fails closed. Rules 12 and 17 read it.
vb_rc=0
verified_by="$(state_ctx_get "$project" verified_by "$issue_arg" 2>/dev/null)" || vb_rc=$?
verified_by="${verified_by//$'\r'/}"
case "$vb_rc:$verified_by" in
    0:preship|0:) vb_forward=0 ;;         # an absent key reads as empty: a legacy record
    *) vb_forward=1 ;;
esac
fwd_text="head ${verified_head:0:7} was recorded by forward and merges only on green CI ($CI_RESULT)"

# rule 12: the PR's live state, not the log — a queue that ejects it, or a cancelled
# auto-merge, falls through to the rules below. The PR is left to the forge only when
# nothing here still has to decide: a forwarded head only on green CI (#1125), and any
# head only when every required check is success and its diff is not self-certifying,
# or is acknowledged for this head (#1097). Otherwise auto-merge is turned off, as rule
# 11 does, and the rules below decide; a merge queue cannot be left from here, so it
# stops. r12_rule/r12_why: the rule that still has to decide, and why.
if [ "$MV_AUTOMERGE" = on ] || [ "$MV_QUEUE" = true ]; then
    r12_rule="" r12_why=""
    if [ "$vb_forward" = 1 ] && [ "$CI_RESULT" != green ]; then
        r12_rule=17 r12_why="$fwd_text"
    elif [ "$RC_OK" != 1 ]; then
        r12_rule=15 r12_why="head ${verified_head:0:7} merges only when every required check is successful"
    elif [ "$SELFCERT_STATE" = paths ]; then
        r12_rule=21 r12_why="head ${verified_head:0:7} merges only when an operator has acknowledged its self-certifying diff"
    elif [ "$SELFCERT_STATE" = unknown ]; then
        r12_rule=21 r12_why="head ${verified_head:0:7} merges only when its self-certifying diff can be read"
    fi
    [ -n "$r12_why" ] || _wait 12 "merge accepted; waiting ($CI_RESULT, $MV_MERGEABLE/$MV_MERGESTATE)$sfx"
    if [ "$MV_QUEUE" = true ]; then
        _stop "$r12_rule" "$r12_why, but the PR is in a merge queue; remove it from the queue on the forge, then run /devagent:unstuck$sfx"
    fi
    _call DEVAGENT_MERGEMR_MERGE_SECS 30 "$code_sh" merge-mr "$mr_url" --disable-auto
    if [ "$_CALL_RC" -ne 0 ]; then
        _stop "$r12_rule" "$r12_why; could not disable auto-merge: $_CALL_ERR; disable it on the forge, then run /devagent:unstuck$sfx"
    fi
    echo "mergemr: auto-merge disabled: $r12_why"
    log_append "$issue_dir" mergemr "auto-merge disabled: $r12_why"
fi
if [ "$MV_MERGEABLE" = UNKNOWN ] || [ "$MV_MERGESTATE" = UNKNOWN ]; then      # rule 13
    _wait 13 "mergeability not computed yet"
fi
# rule 14 (#1125 names the paths): git's own merge of verified_head and the base tip,
# asked in the issue tree after one bounded fetch of the base. The light remedy
# (preship-verified-head.sh forward) only when forward could accept it: verify = "ci",
# every conflicted path in append_only, merged by git as text, and only insertions on
# both sides (the hunk checker's --parse-only), no merge gate in mr.md, and no merge
# driver on any path of git's merged tree.
_r14() {
    local today="merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
    local why="" out rc=0 base_ref tip p joined light=1
    if ! out="$( (active_tree_resolve "$project" "$issue_arg") 2>&1 >/dev/null)"; then
        out="${out%%$'\n'*}"
        _stop 14 "conflict with $MV_BASE (conflicted paths unknown: cannot resolve the issue tree: ${out#*: }); $today"
    fi
    active_tree_resolve "$project" "$issue_arg"     # setter-globals; never $( … )
    local tree="$ACTIVE_TREE_DIR"
    base_ref="$default_baseline_raw"
    _ci_secs DEVAGENT_MERGEMR_FETCH_SECS 20
    upstream_fetch_base "$tree" "$base_ref" "$_CI_SECS"
    case "$BASE_FETCH" in
        failed|notimeout) why="could not fetch '$BASE_FETCH_REMOTE' ($BASE_FETCH_WHY)" ;;
    esac
    if [ -z "$why" ]; then
        tip="$("$DEVAGENT_GIT" -C "$tree" rev-parse --verify --quiet "${base_ref}^{commit}" 2>/dev/null)" \
            || why="cannot resolve ${base_ref:-default_baseline}"
    fi
    if [ -z "$why" ]; then
        merge_forward_merge "$tree" "$verified_head" "$tip" || rc=$?
        case "$rc" in
            0) _stop 14 "conflict with $MV_BASE (git finds no conflict between ${verified_head:0:7} and ${tip:0:7}); $today" ;;
            1) : ;;
            2) why="git merge-tree exited $MF_MERGE_RC" ;;
            3) why="a conflicted path contains a newline" ;;
            *) why="git reports a conflict but names no conflicted path" ;;
        esac
    fi
    [ -z "$why" ] || _stop 14 "conflict with $MV_BASE (conflicted paths unknown: $why); $today"

    joined="${MF_CONFLICTED[0]}"
    for p in "${MF_CONFLICTED[@]:1}"; do joined+=", $p"; done

    # Each check below mirrors a forward refusal (never a remedy forward always refuses);
    # the cheap ones first.
    [ "$MF_VERIFY" = ci ] || light=0
    for p in "${MF_CONFLICTED[@]}"; do
        merge_forward_listed "$p" && [ "${MF_CONFLICT[$p]}" = text ] || light=0
    done
    if [ "$light" = 1 ]; then
        rc=0; merge_forward_gate "$issue_dir" || rc=$?
        [ "$rc" -eq 1 ] || light=0
    fi
    if [ "$light" = 1 ]; then
        merge_forward_drivers "$tree" "$MF_MTREE" || light=0
    fi
    if [ "$light" = 1 ]; then
        for p in "${MF_CONFLICTED[@]}"; do
            merge_forward_insertions "$tree" "$p" || { light=0; break; }
        done
    fi
    if [ "$light" = 1 ]; then
        _stop 14 "conflict only in $joined; merge it forward keeping both sides' lines, run rebaseline.sh, push, then run preship-verified-head.sh forward"
    fi
    _stop 14 "conflict with $MV_BASE in $joined; $today"
}
[ "$MV_MERGEABLE" != CONFLICTING ] || _r14                                     # rule 14

# rules 15-17: #782's verdict, unchanged. ci_gate does not apply here: merging is a
# stronger act than reporting. A required check (#1097) is judged beside it: one that
# ended without success stops at rule 15 even while other checks are pending (a
# terminal conclusion at this head cannot change), a pending one is a pending check
# (rule 16), and one that did not report waits out the grace (rule 16), then stops.
ci_verdict
case "$CI_VERDICT" in
    red)                                                                      # rule 15
        _stop 15 "$CI_LINE; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship" ;;
    hold|proceed)                                 # rule 15; `;;&` goes on to the verdict's own arm
        [ -z "$RC_BAD" ] || _stop 15 "required check not successful on head ${verified_head:0:7}: $RC_BAD${RC_MISSING:+; not reported: $RC_MISSING}; $R15_REQ_FIX" ;;&
    hold)                                                                     # rule 16
        [ "$CI_RESULT" != none ] || _wait 16 "checks not reported yet (grace ${_CI_SECS}s)"
        _wait 16 "$CI_LINE" ;;
    proceed)                                                                  # rule 16
        if [ -n "$RC_MISSING" ]; then
            _ci_grace_over || _wait 16 "required check not reported yet: $RC_MISSING (grace ${_CI_SECS}s)"
            grace_secs="$_CI_SECS"      # past it: the stop below rule 17's forward arm
        fi ;;
    *) _wait 16 "unexpected CI verdict '$CI_VERDICT'" ;;
esac
# rule 17, a head recorded by forward (#1125): it merges only on green CI, whatever
# merge_checks says (vb_forward, read before rule 12).
if [ "$vb_forward" = 1 ] && [ "$CI_RESULT" != green ]; then
    _stop 17 "$fwd_text; to verify it in full, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
fi
# rule 15 again (#1097), ahead of merge_checks: a required check still not reported
# after the grace (inside it, rule 16 waited above), so "if-present" never merges past it.
if [ -n "$RC_MISSING" ]; then
    _stop 15 "required check not reported on head ${verified_head:0:7} after ${grace_secs}s: $RC_MISSING; start it on the forge and run /devagent:unstuck, or push a head that runs it, then run /devagent:preship"
fi
if [ "$CI_RESULT" = none ] && [ "$MERGE_CHECKS" = required ]; then           # rule 17
    _stop 17 "no CI checks on head commit; set merge_checks = \"if-present\" to merge without CI, then run /devagent:unstuck"
fi
case "$MV_MERGESTATE" in                                                      # rule 18
    CLEAN|HAS_HOOKS) ;;
    *) _stop 18 "blocked by a forge rule ($MV_MERGESTATE); resolve it on the forge, then run /devagent:unstuck" ;;
esac

# rule 15 once more (#1097), the merge's precondition stated in one place: nothing
# below runs while a required check is not success. The verdict arms above already
# stop or wait on every such state (a bad, pending or missing check), so this is
# unreachable until one of them changes; it names every required check and its state.
if [ "${#REQUIRED_CHECKS[@]}" -gt 0 ] && [ "$RC_OK" != 1 ]; then
    _stop 15 "required check not successful on head ${verified_head:0:7}: $RC_REPORT; $R15_REQ_FIX"
fi

# rule 21 (#1097), the self-certification stop. It sits here, after the CI verdict is
# green and every forge rule has passed, so one acknowledgment covers one green head;
# and ahead of rule 19's own stop, which sends the operator to merge by hand. It is
# the operator's: no preship record and no forward clears it, and its text carries no
# command to copy. An acknowledged diff is printed on every run and logged once per
# recorded head.
case "$SELFCERT_STATE" in
    unknown)
        [ -z "$SELFCERT_BAD_ENTRY" ] || SELFCERT_WHY+="; fix the key, or merge the base forward"
        _stop 21 "self-certifying diff unknown: $SELFCERT_WHY; fix that, then run /devagent:unstuck" ;;
    paths)
        _stop 21 "self-certifying diff: $SELFCERT_LIST changed in ${SELFCERT_BASE:0:7}..${verified_head:0:7}, so this PR can change what its required checks measure. Operator only (reviewed workflow change only): record the review in $issue_dir/.devagent-selfcert-ack as commands/mergemr.md \"Escapes\" describes, then /devagent:unstuck" ;;
    acked)
        _ack_msg="self-certifying diff acknowledged at ${verified_head:0:7}: $SELFCERT_LIST — $SELFCERT_ACK_REASON"
        echo "mergemr: $_ack_msg"
        _logged_since_head "$_ack_msg" || log_append "$issue_dir" mergemr "$_ack_msg" ;;
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
[ "$_CALL_RC" -eq 0 ] || _stop 19 "merge call failed: $_CALL_ERR; then run /devagent:unstuck"

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
