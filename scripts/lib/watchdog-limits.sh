#!/usr/bin/env bash
# scripts/lib/watchdog-limits.sh — #932: the watchdog's limits, the --silent
# window grammar and the --since time, each with this one home.
# Requires paths.sh and config.sh sourced first (config_path, _config_toml).
#
# Config keys are integer seconds, 1..604800, resolved project -> [defaults] ->
# constant. Nothing here dies or prints: every function reports through setter
# globals and its return code, and the caller owns the failure policy (`check`
# exits 1 on a malformed or unreadable limit; next.sh, long-run.sh and
# `heartbeat` warn and use the constant, since they must never fail a run).
# Call them bare, with `|| rc=$?` under `set -e`; never inside `$( … )`.
#
#   watchdog_no_progress_secs   1200   [defaults], project override
#   watchdog_telemetry_secs      180   [defaults], project override
#   watchdog_silent_max_secs    3600   [defaults] only: a project-level key is
#                                      never read (doctor fails it)
#   analyze_silent_secs      derived   [defaults], project override; unset means
#                                      min(analyze_timeout, the maximum)

# shellcheck disable=SC2034  # the constants and setter globals are read by callers
WATCHDOG_DEFAULT_NO_PROGRESS_SECS=1200   # 20 min
WATCHDOG_DEFAULT_TELEMETRY_SECS=180      # 3 min
WATCHDOG_DEFAULT_SILENT_MAX_SECS=3600    # 60 min
WATCHDOG_DEFAULT_ANALYZE_TIMEOUT=1800    # the analyze legs' own default budget
WATCHDOG_SECS_RE='^[1-9][0-9]{0,5}$'     # matched before any arithmetic
WATCHDOG_SECS_MAX=604800                 # 7 days
WATCHDOG_KEYS="watchdog_no_progress_secs watchdog_telemetry_secs watchdog_silent_max_secs"
WATCHDOG_SINCE_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'

# watchdog_secs_ok <text> — 0 iff <text> is integer seconds in 1..604800.
watchdog_secs_ok() {
  [[ "${1:-}" =~ $WATCHDOG_SECS_RE ]] || return 1
  (( 10#$1 <= WATCHDOG_SECS_MAX ))
}

# watchdog_read <dotted key> — one config read (one python parse). Sets
# WATCHDOG_RAW to what the reader printed (`table` for a table). Returns
#   0  a value in range (a quoted integer reads like a bare one)
#   1  absent
#   2  malformed: out of range, not an integer, or a table
#   3  config unreadable (the reader's rc >= 2, or 127)
watchdog_read() {
  local _wl_out _wl_rc=0
  WATCHDOG_RAW=""
  _wl_out="$(_config_toml get "$(config_path 2>/dev/null)" "${1:-}" 2>&1)" || _wl_rc=$?
  _wl_out="${_wl_out//$'\r'/}"
  case "$_wl_rc" in
    0) WATCHDOG_RAW="$_wl_out"
       watchdog_secs_ok "$_wl_out" || return 2
       return 0 ;;
    1) [[ "$_wl_out" == *"is a table, not a value"* ]] || return 1
       WATCHDOG_RAW=table
       return 2 ;;
    *) return 3 ;;
  esac
}

# watchdog_limit <key> [<project>] [<analyze timeout>] — sets WATCHDOG_LIMIT and
# WATCHDOG_LIMIT_SRC (project | defaults | constant | derived). Returns
#   0  WATCHDOG_LIMIT holds seconds
#   1  <key> is not one of the four keys
#   2  the configured value is malformed (never replaced by a constant)
#   3  the config is unreadable (never replaced by a constant)
# On 2 and 3 WATCHDOG_LIMIT is empty and WATCHDOG_LIMIT_SRC names the scope read.
# analyze_silent_secs has no constant: unset, it is min(analyze timeout, the
# maximum), source `derived`. The timeout is the third argument when the caller
# has already resolved one, else the project's analyze_timeout, else 1800; a
# timeout that is not seconds in range leaves the maximum.
watchdog_limit() {
  local _wl_key="${1:-}" _wl_project="${2:-}" _wl_timeout="${3:-}" _wl_const="" _wl_scope _wl_r
  WATCHDOG_LIMIT="" WATCHDOG_LIMIT_SRC=""
  case "$_wl_key" in
    watchdog_no_progress_secs) _wl_const="$WATCHDOG_DEFAULT_NO_PROGRESS_SECS" ;;
    watchdog_telemetry_secs)   _wl_const="$WATCHDOG_DEFAULT_TELEMETRY_SECS" ;;
    watchdog_silent_max_secs)  _wl_const="$WATCHDOG_DEFAULT_SILENT_MAX_SECS"; _wl_project="" ;;
    analyze_silent_secs)       ;;
    *) return 1 ;;
  esac
  for _wl_scope in ${_wl_project:+project} defaults; do
    _wl_r=0
    if [[ "$_wl_scope" == project ]]; then
      watchdog_read "project.${_wl_project}.${_wl_key}" || _wl_r=$?
    else
      watchdog_read "defaults.${_wl_key}" || _wl_r=$?
    fi
    case "$_wl_r" in
      0) WATCHDOG_LIMIT="$WATCHDOG_RAW" WATCHDOG_LIMIT_SRC="$_wl_scope"; return 0 ;;
      1) ;;
      *) WATCHDOG_LIMIT_SRC="$_wl_scope"; return "$_wl_r" ;;
    esac
  done
  if [[ -n "$_wl_const" ]]; then
    WATCHDOG_LIMIT="$_wl_const" WATCHDOG_LIMIT_SRC=constant
    return 0
  fi
  # analyze_silent_secs, unset: derive it.
  local _wl_max
  _wl_r=0
  watchdog_limit watchdog_silent_max_secs || _wl_r=$?
  if (( _wl_r != 0 )); then WATCHDOG_LIMIT=""; return "$_wl_r"; fi
  _wl_max="$WATCHDOG_LIMIT"
  if [[ -z "$_wl_timeout" && -n "$_wl_project" ]]; then
    _wl_timeout="$(_config_toml get "$(config_path 2>/dev/null)" "project.${_wl_project}.analyze_timeout" 2>/dev/null)" || _wl_timeout=""
    _wl_timeout="${_wl_timeout//$'\r'/}"
  fi
  [[ -n "$_wl_timeout" ]] || _wl_timeout="$WATCHDOG_DEFAULT_ANALYZE_TIMEOUT"
  WATCHDOG_LIMIT="$_wl_max" WATCHDOG_LIMIT_SRC=derived
  if watchdog_secs_ok "$_wl_timeout" && (( 10#$_wl_timeout < _wl_max )); then
    WATCHDOG_LIMIT="$_wl_timeout"
  fi
  return 0
}

# watchdog_analyze_window <project> <analyze timeout> — the silent window every
# analyze leg declares, resolved once before any leg runs. Sets
# WATCHDOG_ANALYZE_SECS and WATCHDOG_ANALYZE_NOTE. Returns
#   0  WATCHDOG_ANALYZE_SECS holds seconds within the maximum. The note is
#      empty, or a warning for the caller to print: analyze_silent_secs (or the
#      maximum) could not be read, and the window is the derived one,
#      min(<analyze timeout>, the maximum), by the shipped maximum if need be.
#   2  analyze_silent_secs is set above the maximum: nothing may run. The note
#      names the key, its value and the maximum.
watchdog_analyze_window() {
  local _wa_project="${1:-}" _wa_timeout="${2:-}" _wa_r=0 _wa_mr=0 _wa_value _wa_src _wa_max _wa_why=""
  WATCHDOG_ANALYZE_SECS="" WATCHDOG_ANALYZE_NOTE=""
  watchdog_limit analyze_silent_secs "$_wa_project" "$_wa_timeout" || _wa_r=$?
  _wa_value="$WATCHDOG_LIMIT" _wa_src="$WATCHDOG_LIMIT_SRC"
  if (( _wa_r == 0 )) && [[ "$_wa_src" == derived ]]; then
    WATCHDOG_ANALYZE_SECS="$_wa_value"
    return 0
  fi
  case "$_wa_r" in
    0) ;;
    2) _wa_why="analyze_silent_secs is not seconds from 1 to ${WATCHDOG_SECS_MAX}${_wa_src:+ in [${_wa_src}]}" ;;
    *) _wa_why="analyze_silent_secs could not be read from the config" ;;
  esac
  watchdog_limit watchdog_silent_max_secs || _wa_mr=$?
  _wa_max="$WATCHDOG_LIMIT"
  if (( _wa_mr != 0 )); then
    _wa_max="$WATCHDOG_DEFAULT_SILENT_MAX_SECS"
    # An unset key fails here too (its derivation reads the maximum), so the
    # maximum is the one fault this can name.
    _wa_why="watchdog_silent_max_secs could not be read, so the shipped maximum of ${_wa_max} s stands in"
  fi
  if (( _wa_r == 0 )); then
    if (( 10#$_wa_value > 10#$_wa_max )); then
      WATCHDOG_ANALYZE_NOTE="analyze_silent_secs = ${_wa_value} s (${_wa_src}) exceeds the silent-window maximum, watchdog_silent_max_secs = ${_wa_max} s; set a window within the maximum (the maximum is operator-set, in [defaults])"
      return 2
    fi
    WATCHDOG_ANALYZE_SECS="$_wa_value"
  else
    WATCHDOG_ANALYZE_SECS="$_wa_max"
    if watchdog_secs_ok "$_wa_timeout" && (( 10#$_wa_timeout < 10#$_wa_max )); then
      WATCHDOG_ANALYZE_SECS="$_wa_timeout"
    fi
  fi
  [[ -z "$_wa_why" ]] || WATCHDOG_ANALYZE_NOTE="${_wa_why} (doctor names the value); the analyze legs declare a silent window of ${WATCHDOG_ANALYZE_SECS} s"
  return 0
}

# watchdog_window <text> [<project>] [<maximum>] — the --silent grammar:
# <N> or <N>m is N minutes (exactly N x 60 s), <N>s is N seconds, N matching
# ^[1-9][0-9]{0,5}$. Sets WATCHDOG_WINDOW_SECS. Returns
#   0  the window is within the maximum
#   2  refused; WATCHDOG_WINDOW_ERR holds the text (the caller adds its prefix)
#   3  the grammar holds (WATCHDOG_WINDOW_SECS is set) but the maximum could not
#      be resolved; WATCHDOG_WINDOW_ERR says so
# <maximum> is for a caller that has already resolved it under its own failure
# policy: with it no config is read. The maximum is [defaults]-only, so
# <project> changes nothing today.
watchdog_window() {
  local _ww_text="${1:-}" _ww_max="${3:-}" _ww_n _ww_r=0
  WATCHDOG_WINDOW_SECS="" WATCHDOG_WINDOW_ERR=""
  _ww_n="${_ww_text%[ms]}"
  if ! [[ "$_ww_n" =~ $WATCHDOG_SECS_RE ]]; then
    WATCHDOG_WINDOW_ERR="--silent ${_ww_text} is not a window; write <N> or <N>m for minutes or <N>s for seconds, N from 1 to 999999"
    return 2
  fi
  case "$_ww_text" in
    *s) WATCHDOG_WINDOW_SECS="$(( 10#$_ww_n ))" ;;
    *)  WATCHDOG_WINDOW_SECS="$(( 10#$_ww_n * 60 ))" ;;
  esac
  if [[ -z "$_ww_max" ]]; then
    watchdog_limit watchdog_silent_max_secs "${2:-}" || _ww_r=$?
    _ww_max="${WATCHDOG_LIMIT:-}"
  fi
  if (( _ww_r != 0 )) || ! watchdog_secs_ok "$_ww_max"; then
    WATCHDOG_WINDOW_ERR="cannot read watchdog_silent_max_secs, the silent-window maximum"
    return 3
  fi
  if (( WATCHDOG_WINDOW_SECS > 10#$_ww_max )); then
    WATCHDOG_WINDOW_ERR="--silent ${_ww_text} exceeds the silent-window maximum of ${_ww_max} s; declare a shorter window (the maximum is operator-set and is not changed from a session)"
    return 2
  fi
  return 0
}

# watchdog_parse_since <ISO time> — sets WATCHDOG_SINCE_EPOCH (whole seconds; a
# fraction is dropped). The zone is required. Returns
#   0  converted
#   2  not the --since form, or not a real instant (month 13, 25:00, +99:00)
#   3  python3 could not convert it
watchdog_parse_since() {
  local _ws_norm _ws_zone _ws_out _ws_rc=0
  WATCHDOG_SINCE_EPOCH=""
  [[ "${1:-}" =~ $WATCHDOG_SINCE_RE ]] || return 2
  _ws_zone="${BASH_REMATCH[3]}"
  [[ "$_ws_zone" != Z ]] || _ws_zone="+00:00"
  _ws_norm="${BASH_REMATCH[1]}${_ws_zone}"
  # Python 3.8 syntax; fromisoformat before 3.11 takes neither Z nor a fraction
  # of other than 3 or 6 digits, hence the normalised form.
  _ws_out="$(python3 -c '
import datetime, sys
try:
    t = datetime.datetime.fromisoformat(sys.argv[1]).timestamp()
except (ValueError, OverflowError):
    sys.exit(2)
if t < 0:
    sys.exit(2)
sys.stdout.write("%d\n" % int(t))
' "$_ws_norm" 2>/dev/null)" || _ws_rc=$?
  _ws_out="${_ws_out//$'\r'/}"
  case "$_ws_rc" in
    0) [[ "$_ws_out" =~ ^[0-9]{1,12}$ ]] || return 3
       WATCHDOG_SINCE_EPOCH="$_ws_out"
       return 0 ;;
    2) return 2 ;;
    *) return 3 ;;
  esac
}
