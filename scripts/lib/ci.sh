#!/usr/bin/env bash
# scripts/lib/ci.sh — the MR's CI status after ship (#782): one bounded read of the
# code backend's `mr-checks` verb, turned into one result, one `CI …:` line, one
# deduplicated `ci:` log line, and a gate verdict. next.sh prints the line on every
# invocation in the ship-to-merge window; mergetoall.sh requires green; `ci_gate =
# "block"` gates every post-ship step. Nothing here waits for CI. ci_read_view
# (#885) reads the superset verb `mr-view` through the same fetch and parser for
# the merge step (mergemr.sh), and merge_checks_resolve/merge_method_resolve validate
# that step's two config keys.
#
# Every ci_* function is a SETTER-GLOBAL: call it bare, never as $(...) (register
# Issue-282; ci_gate_resolve's die must exit the caller, Issue-120). Expects
# paths/io/config/state/active/checklist/log to be sourced already, as the step
# scripts do. Sources upstream.sh for bounded_call; a second source of upstream.sh
# by the caller (mergetoall.sh) is intentional and idempotent.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/upstream.sh"

# _ci_secs <env-name> <default>: sets _CI_SECS to the named knob when it is 1-99999
# whole seconds, else warns (when set) and uses <default> (register Issue-774: a digit
# regex alone does not bound size).
_ci_secs() {
  local name="$1" def="$2" v="${!1:-}"
  _CI_SECS="$def"
  [ -n "$v" ] || return 0
  if [[ "$v" =~ ^[1-9][0-9]{0,4}$ ]]; then
    _CI_SECS="$v"
  else
    warn "$name must be 1-99999 seconds (got '$v'); using $def"
  fi
}

# ci_gate_resolve <project>: sets CI_GATE from `[project.<name>] ci_gate`, else
# `[defaults] ci_gate`, else `report`. Any other value dies (Issue-780: an opt-out key
# must not be misspelled into silence).
# shellcheck disable=SC2034  # CI_GATE is the return channel — read by next.sh/mergetoall.sh
ci_gate_resolve() {
  local v
  _ci_key_resolve "$1" ci_gate report; v="$_CI_KEY_VAL"
  case "$v" in
    report|block|off) CI_GATE="$v" ;;
    *) die "ci_gate must be report, block or off (got '$v')" ;;
  esac
}

# _ci_key_resolve <project> <key> <default>: `[project.<name>] <key>`, else `[defaults]
# <key>`, else <default>, CR-stripped, in _CI_KEY_VAL; the table it came from in
# _CI_KEY_TABLE (`project.<name>` or `defaults`), so a die names the line to fix.
_ci_key_resolve() {
  local v
  if v="$(config_get_project_field "$1" "$2" 2>/dev/null)"; then _CI_KEY_TABLE="project.$1"
  elif v="$(config_get_default "$2" 2>/dev/null)"; then _CI_KEY_TABLE=defaults
  else v="$3"; _CI_KEY_TABLE="project.$1"
  fi
  _CI_KEY_VAL="${v//$'\r'/}"
}

# merge_checks_resolve <project> (#885): sets MERGE_CHECKS from merge_checks, as
# ci_gate_resolve reads ci_gate: `required` (default; the merge step stops when the
# PR's head reports no CI checks) or `if-present` (it merges without them). Any other
# value dies naming the key, whatever permissions.merge_mr says (Issue-780).
# shellcheck disable=SC2034  # MERGE_CHECKS is the return channel — read by mergemr.sh
merge_checks_resolve() {
  _ci_key_resolve "$1" merge_checks required
  case "$_CI_KEY_VAL" in
    required|if-present) MERGE_CHECKS="$_CI_KEY_VAL" ;;
    *) die "merge_checks must be required or if-present (got '$_CI_KEY_VAL'); fix [$_CI_KEY_TABLE] merge_checks" ;;
  esac
}

# merge_method_resolve <project> (#885): sets MERGE_METHOD from merge_method: `squash`
# (default), `merge` or `rebase`. Any other value dies naming the key.
# shellcheck disable=SC2034  # MERGE_METHOD is the return channel — read by mergemr.sh
merge_method_resolve() {
  _ci_key_resolve "$1" merge_method squash
  case "$_CI_KEY_VAL" in
    squash|merge|rebase) MERGE_METHOD="$_CI_KEY_VAL" ;;
    *) die "merge_method must be squash, merge or rebase (got '$_CI_KEY_VAL'); fix [$_CI_KEY_TABLE] merge_method" ;;
  esac
}

# _ci_record_head <project> <issue> <head>: the per-head grace clock. Sets CI_SEEN_AT
# to the epoch the state first saw <head>; a head it has not seen gets ci_seen_head +
# ci_seen_at=now in ONE write. A failed write warns and leaves CI_SEEN_AT empty, so a
# `none` verdict holds rather than judge this head by another head's clock.
_ci_record_head() {
  local project="$1" issue="$2" head="$3" seen now
  seen="$(state_issue_get "$project" "$issue" ci_seen_head 2>/dev/null || true)"
  if [ "$seen" = "$head" ]; then
    CI_SEEN_AT="$(state_issue_get "$project" "$issue" ci_seen_at 2>/dev/null || true)"
    return 0
  fi
  now="$(date +%s)"
  if ( state_ctx_set_many "$project" "$issue" str ci_seen_head "$head" str ci_seen_at "$now" ); then
    CI_SEEN_AT="$now"
  else
    warn "ci: could not record ci_seen_head for $issue"
  fi
}

_ci_unknown() { CI_LINE="CI UNKNOWN: $1: $2"; _CI_REASON="$2"; }

# _ci_call <knob> <default> <cmd> [args...]: one bounded call, stdin from /dev/null,
# bounded by the <knob> seconds (_ci_secs, <default>). Sets _CALL_OUT (stdout),
# _CALL_RC (its exit code; 127 when timeout(1) is not on PATH), _CALL_ERRS (its
# non-blank stderr lines) and _CALL_ERR (a bare reason: `timed out after Ns`, the
# last of those lines, else `<cmd> exited <rc>`). Never fails. Shared by _ci_fetch
# and mergemr.sh's backend calls.
_ci_call() {
  local knob="$1" def="$2" errf; shift 2
  _CALL_OUT=""; _CALL_RC=0; _CALL_ERRS=""; _CALL_ERR=""
  if ! command -v timeout >/dev/null 2>&1; then
    _CALL_RC=127; _CALL_ERR="timeout(1) not on PATH"; return 0
  fi
  _ci_secs "$knob" "$def"
  errf="$(mktemp 2>/dev/null)" || errf=/dev/null
  _CALL_OUT="$(bounded_call "$_CI_SECS" "$@" </dev/null 2>"$errf")" || _CALL_RC=$?
  case "$_CALL_RC" in
    0) ;;
    124|137) _CALL_ERR="timed out after ${_CI_SECS}s" ;;
    *)
      _CALL_ERRS="$( { grep -v '^[[:space:]]*$' "$errf" 2>/dev/null || true; } | tr -d '\r')"
      _CALL_ERR="${_CALL_ERRS##*$'\n'}"
      [ -n "$_CALL_ERR" ] || _CALL_ERR="$(basename "$1") exited $_CALL_RC" ;;
  esac
  [ "$errf" = /dev/null ] || rm -f "$errf"
  return 0
}

# _ci_fetch <project> <url> <verb> <knob> <default>: one bounded read of the code
# backend's <verb> on <url> (_ci_call). Sets _CI_OUT to its stdout and returns 0; on
# any failure sets CI_RESULT/CI_LINE (notchecked or unknown) and _CI_REASON (the bare
# reason) and returns 1.
_ci_fetch() {
  local project="$1" url="$2" verb="$3" knob="$4" def="$5" backend script last
  _CI_OUT=""; _CI_REASON=""
  backend="$(config_get_project_field "$project" code_source.backend 2>/dev/null || true)"
  backend="${backend//$'\r'/}"
  script="${DEVAGENT_CODE_BACKEND_DIR:-$(plugin_root)/scripts/code}/$backend.sh"
  if [ -z "$backend" ]; then
    CI_RESULT=notchecked; CI_LINE="CI NOT CHECKED: (none) has no $verb"; _CI_REASON="(none) has no $verb"
    return 1
  fi
  # A configured backend with no runnable script is a broken install, not a backend
  # without the verb (that one answers 2/78 below): unknown holds the gate.
  if [ ! -x "$script" ]; then
    _ci_unknown "$url" "$backend.sh not found or not executable"
    return 1
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    _ci_unknown "$url" "timeout(1) not on PATH"
    return 1
  fi
  _ci_call "$knob" "$def" "$script" "$verb" "$url"
  _CI_OUT="$_CALL_OUT"
  case "$_CALL_RC" in
    0) return 0 ;;
    78|2) CI_RESULT=notchecked; CI_LINE="CI NOT CHECKED: $backend has no $verb"; _CI_REASON="$backend has no $verb" ;;
    124|137) _ci_unknown "$url" "$_CALL_ERR" ;;
    *)
      last="${_CALL_ERRS##*$'\n'}"
      # The CI line carries only the bare last line; the lines above it are the backend's
      # own diagnosis (gh's HTTP 401/404, a DNS failure), so they go to stderr, not away.
      [[ "$_CALL_ERRS" != *$'\n'* ]] || warn "ci: $backend $verb: ${_CALL_ERRS%$'\n'*}"
      _ci_unknown "$url" "${last:-$backend $verb exited $_CALL_RC}" ;;
  esac
  return 1
}

# _ci_view_kind <kind> <field> <field2>: stores one mr-view singleton in its MV_*
# global; returns 1 when the value is not one the grammar allows.
_ci_view_kind() {
  local k="$1" v="$2" v2="$3"
  case "$k" in
    draft)       [[ "$v" =~ ^(true|false)$ ]] && MV_DRAFT="$v" ;;
    base)        [ -n "$v" ] && [ "$v" != - ] && MV_BASE="$v" ;;
    mergeable)   [[ "$v" =~ ^(MERGEABLE|CONFLICTING|UNKNOWN)$ ]] && MV_MERGEABLE="$v" ;;
    mergestate)  [[ "$v" =~ ^[A-Z_]+$ ]] && MV_MERGESTATE="$v" ;;
    automerge)   [[ "$v" =~ ^(on|off)$ ]] && MV_AUTOMERGE="$v" ;;
    queue)       [[ "$v" =~ ^(true|false)$ ]] && MV_QUEUE="$v" ;;
    number)      [[ "$v" =~ ^[1-9][0-9]{0,8}$ ]] && MV_NUMBER="$v" ;;
    title)       [ -n "$v" ] && MV_TITLE="$v" ;;
    mergecommit) [[ "$v" =~ ^([0-9a-f]{40}|-)$ ]] && MV_MERGECOMMIT="$v" ;;
    commits)     [[ "$v" =~ ^(0|[1-9][0-9]{0,8})$ ]] && [[ "$v2" =~ ^(0|[1-9][0-9]{0,8})$ ]] \
                   && MV_COMMITS_TOTAL="$v" && MV_COMMITS_READ="$v2" ;;
    *) false ;;
  esac
}

# _ci_parse <project> <issue> <url> <verb> <mode>: classifies _CI_OUT. Mode `strict`
# (mr-checks) accepts only state/head/pass/pending/fail; mode `view` (mr-view) also
# the singleton kinds of _ci_view_kind plus closes/trailer, into the MV_* globals.
# Any other kind is bad: CI UNKNOWN "unrecognised <verb> output". In view mode a
# missing, invalid or repeated singleton leaves the CI result standing but sets
# MV_ERR (MV_OK stays 0).
_ci_parse() {
  local project="$1" issue="$2" url="$3" verb="$4" mode="$5" out="$_CI_OUT"
  local state="" head="" b name link concl item n=0 bad=0 mv_bad="" k
  local -a pend=() fails=()
  local -A seen=()
  out="${out//$'\r'/}"
  while IFS=$'\t' read -r b name link concl; do
    case "$b" in
      state) state="$name" ;;
      head)  head="$name" ;;
      pass)  n=$((n + 1)) ;;
      pending) n=$((n + 1)); pend+=("$name") ;;
      fail)
        n=$((n + 1)); item="$name"
        case "$concl" in FAILURE|ERROR|'') ;; *) item+=" [$concl]" ;; esac
        case "$link" in ''|-) ;; *) item+=" $link" ;; esac   # `-` = no link (§9.2)
        fails+=("$item") ;;
      '') ;;
      draft|base|mergeable|mergestate|automerge|queue|number|title|mergecommit|commits)
        if [ "$mode" != view ]; then bad=1
        elif [ -n "${seen[$b]:-}" ]; then mv_bad="${mv_bad:-$b repeated}"
        else
          seen[$b]=1
          _ci_view_kind "$b" "$name" "$link" || mv_bad="${mv_bad:-$b invalid}"
        fi ;;
      closes)
        if [ "$mode" != view ]; then bad=1
        elif [[ "$name" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] && [[ "$link" =~ ^[1-9][0-9]*$ ]]; then
          MV_CLOSES+=("$name#$link")
        else mv_bad="${mv_bad:-closes invalid}"
        fi ;;
      trailer)
        if [ "$mode" != view ]; then bad=1
        elif [ -n "$name" ]; then MV_TRAILERS+=("$name")
        else mv_bad="${mv_bad:-trailer invalid}"
        fi ;;
      *) bad=1 ;;
    esac
  done <<<"$out"
  case "$state" in open|merged|closed) ;; *) bad=1 ;; esac
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || bad=1
  if [ "$bad" -eq 1 ]; then
    _ci_unknown "$url" "unrecognised $verb output"
    return 0
  fi
  CI_HEAD="$head"
  _ci_record_head "$project" "$issue" "$head"
  local at="$url (head ${head:0:7})" joined
  if [ "$state" != open ]; then
    CI_RESULT="$state"
  elif [ "${#fails[@]}" -gt 0 ]; then
    joined="$(printf '; %s' "${fails[@]}")"
    CI_RESULT=red; CI_LINE="CI FAILED: $at: ${joined#; }"
  elif [ "${#pend[@]}" -gt 0 ]; then
    joined="$(printf ', %s' "${pend[@]}")"
    CI_RESULT=pending; CI_LINE="CI PENDING: ${#pend[@]} of $n checks still running on $at: ${joined#, }"
  elif [ "$n" -gt 0 ]; then
    CI_RESULT=green; CI_LINE="CI PASSED: $n checks on $at"
  else
    CI_RESULT=none; CI_LINE="CI NONE: no checks reported on $at"
  fi
  [ "$mode" = view ] || return 0
  for k in draft base mergeable mergestate automerge queue number title mergecommit commits; do
    [ -n "${seen[$k]:-}" ] || mv_bad="${mv_bad:-$k missing}"
  done
  if [ -z "$mv_bad" ]; then MV_OK=1; else MV_ERR="unrecognised $verb output: $mv_bad"; fi
  return 0
}

# ci_read <project> <issue> <mr_url>: sets CI_RESULT (red|pending|green|none|merged|
# closed|notchecked|unknown), CI_LINE, CI_HEAD and CI_SEEN_AT from the backend's
# mr-checks, bounded by DEVAGENT_CI_READ_SECS (default 20). Never dies; returns 0.
# A failed or unparseable read is `unknown`, never `none` or `green` (register
# Issue-243): the gate holds on it.
ci_read() {
  local project="$1" issue="$2" url="$3"
  CI_RESULT=unknown; CI_LINE=""; CI_HEAD=""; CI_SEEN_AT=""
  _ci_fetch "$project" "$url" mr-checks DEVAGENT_CI_READ_SECS 20 || return 0
  _ci_parse "$project" "$issue" "$url" mr-checks strict
}

# ci_read_view <project> <issue> <mr_url> (#885): the merge step's one read of the
# PR. Reads the backend's mr-view (mr-checks' lines plus the merge facts), bounded
# by DEVAGENT_MERGEMR_READ_SECS (default 20), and sets ci_read's CI_* globals from
# the same lines, plus:
#   MV_OK             1 only when every singleton kind is present and valid, else 0
#   MV_ERR            why not, a bare reason (the backend's last stderr line, `timed
#                     out after Ns`, `<backend> has no mr-view`, `unrecognised
#                     mr-view output[: <kind> missing|invalid|repeated]`); empty
#                     when MV_OK=1
#   MV_DRAFT MV_QUEUE true|false
#   MV_BASE MV_TITLE  text
#   MV_MERGEABLE      MERGEABLE|CONFLICTING|UNKNOWN
#   MV_MERGESTATE     GitHub's mergeStateStatus (CLEAN, BLOCKED, ...)
#   MV_AUTOMERGE      on|off
#   MV_NUMBER         the PR number
#   MV_MERGECOMMIT    <40-hex> or -
#   MV_CLOSES         array of owner/name#n, one per closing reference
#   MV_TRAILERS       array of distinct Signed-off-by:/Co-authored-by: lines
#   MV_COMMITS_TOTAL MV_COMMITS_READ   the PR's commit count; the commits read
# Every MV_* is reset first, so a failed read never shows an earlier read's values.
# Never dies; returns 0. A setter-global: call it bare.
# shellcheck disable=SC2034  # MV_* are the return channel — read by mergemr.sh
ci_read_view() {
  local project="$1" issue="$2" url="$3"
  CI_RESULT=unknown; CI_LINE=""; CI_HEAD=""; CI_SEEN_AT=""
  MV_OK=0; MV_ERR=""; MV_DRAFT=""; MV_BASE=""; MV_MERGEABLE=""; MV_MERGESTATE=""
  MV_AUTOMERGE=""; MV_QUEUE=""; MV_NUMBER=""; MV_TITLE=""; MV_MERGECOMMIT=""
  MV_CLOSES=(); MV_TRAILERS=(); MV_COMMITS_TOTAL=""; MV_COMMITS_READ=""
  if ! _ci_fetch "$project" "$url" mr-view DEVAGENT_MERGEMR_READ_SECS 20; then
    MV_ERR="$_CI_REASON"
    return 0
  fi
  _ci_parse "$project" "$issue" "$url" mr-view view
  [ "$CI_RESULT" != unknown ] || MV_ERR="${MV_ERR:-$_CI_REASON}"
  return 0
}

# ci_report <issue_dir>: prints CI_LINE (when there is one) and appends
# `ci: <result> <sha7|-> — <CI_LINE>` to the checklist Log, unless the last `ci:` entry
# already carries the same `<result> <sha7|->`. Never fails: log_append dies on a
# checklist with no `## Log`, so it runs in a subshell.
ci_report() {
  local issue_dir="$1" key last
  [ -n "$CI_LINE" ] || return 0
  printf '%s\n' "$CI_LINE"
  key="$CI_RESULT ${CI_HEAD:0:7}"
  [ -n "$CI_HEAD" ] || key="$CI_RESULT -"
  last="$( { grep -E '^- .*  ci: ' "$issue_dir/checklist.md" 2>/dev/null || true; } \
    | tail -n 1 | sed -E 's/^.*  ci: ([^ ]+ [^ ]+).*/\1/')"
  [ "$last" = "$key" ] && return 0
  ( log_append "$issue_dir" ci "$key — $CI_LINE" ) 2>/dev/null || true
}

# ci_verdict: sets CI_VERDICT from ci_read's CI_RESULT — red; hold (pending, unknown,
# or none inside DEVAGENT_CI_GRACE_SECS, default 120 s, of CI_SEEN_AT: checks may not
# have registered yet); else proceed. An empty or garbled CI_SEEN_AT holds, and so does
# an unrecognised result (fail closed).
# shellcheck disable=SC2034  # CI_VERDICT is the return channel — read by next.sh/mergetoall.sh
ci_verdict() {
  case "${CI_RESULT:-}" in
    red) CI_VERDICT=red ;;
    pending|unknown) CI_VERDICT=hold ;;
    none)
      _ci_secs DEVAGENT_CI_GRACE_SECS 120
      if [[ "${CI_SEEN_AT:-}" =~ ^[0-9]+$ ]] \
         && (( $(date +%s) - 10#$CI_SEEN_AT >= _CI_SECS )); then
        CI_VERDICT=proceed
      else
        CI_VERDICT=hold
      fi ;;
    green|notchecked|merged|closed) CI_VERDICT=proceed ;;
    *) CI_VERDICT=hold ;;
  esac
}
