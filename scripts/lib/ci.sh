#!/usr/bin/env bash
# scripts/lib/ci.sh — the MR's CI status after ship (#782): one bounded read of the
# code backend's `mr-checks` verb, turned into one result, one `CI …:` line, one
# deduplicated `ci:` log line, and a gate verdict. next.sh prints the line on every
# invocation in the ship-to-merge window; mergetoall.sh requires green; `ci_gate =
# "block"` gates every post-ship step. Nothing here waits for CI.
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
  if v="$(config_get_project_field "$1" ci_gate 2>/dev/null)"; then :
  elif v="$(config_get_default ci_gate 2>/dev/null)"; then :
  else v=report
  fi
  v="${v//$'\r'/}"
  case "$v" in
    report|block|off) CI_GATE="$v" ;;
    *) die "ci_gate must be report, block or off (got '$v')" ;;
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

_ci_unknown() { CI_LINE="CI UNKNOWN: $1: $2"; }

# ci_read <project> <issue> <mr_url>: sets CI_RESULT (red|pending|green|none|merged|
# closed|notchecked|unknown), CI_LINE, CI_HEAD and CI_SEEN_AT. Never dies; returns 0.
# A failed or unparseable read is `unknown`, never `none` or `green` (register
# Issue-243): the gate holds on it.
ci_read() {
  local project="$1" issue="$2" url="$3" backend script out="" rc=0 errf errs last secs
  CI_RESULT=unknown; CI_LINE=""; CI_HEAD=""; CI_SEEN_AT=""
  backend="$(config_get_project_field "$project" code_source.backend 2>/dev/null || true)"
  backend="${backend//$'\r'/}"
  script="${DEVAGENT_CODE_BACKEND_DIR:-$(plugin_root)/scripts/code}/$backend.sh"
  if [ -z "$backend" ] || [ ! -x "$script" ]; then
    CI_RESULT=notchecked; CI_LINE="CI NOT CHECKED: ${backend:-(none)} has no mr-checks"
    return 0
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    _ci_unknown "$url" "timeout(1) not on PATH"
    return 0
  fi
  _ci_secs DEVAGENT_CI_READ_SECS 20; secs="$_CI_SECS"
  errf="$(mktemp 2>/dev/null)" || errf=/dev/null
  out="$(bounded_call "$secs" "$script" mr-checks "$url" </dev/null 2>"$errf")" || rc=$?
  case "$rc" in
    0) ;;
    78|2) CI_RESULT=notchecked; CI_LINE="CI NOT CHECKED: $backend has no mr-checks" ;;
    124|137) _ci_unknown "$url" "timed out after ${secs}s" ;;
    *)
      errs="$( { grep -v '^[[:space:]]*$' "$errf" 2>/dev/null || true; } | tr -d '\r')"
      last="${errs##*$'\n'}"
      # The CI line carries only the bare last line; the lines above it are the backend's
      # own diagnosis (gh's HTTP 401/404, a DNS failure), so they go to stderr, not away.
      [[ "$errs" != *$'\n'* ]] || warn "ci: $backend mr-checks: ${errs%$'\n'*}"
      _ci_unknown "$url" "${last:-$backend mr-checks exited $rc}" ;;
  esac
  [ "$errf" = /dev/null ] || rm -f "$errf"
  [ "$rc" -eq 0 ] || return 0

  local state="" head="" b name link concl item n=0 bad=0
  local -a pend=() fails=()
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
        [ -z "$link" ] || item+=" $link"
        fails+=("$item") ;;
      '') ;;
      *) bad=1 ;;
    esac
  done <<<"$out"
  case "$state" in open|merged|closed) ;; *) bad=1 ;; esac
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || bad=1
  if [ "$bad" -eq 1 ]; then
    _ci_unknown "$url" "unrecognised mr-checks output"
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
