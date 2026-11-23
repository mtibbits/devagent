#!/usr/bin/env bash
# scripts/watchdog.sh — #932: the no-progress watchdog's two questions.
#
#   watchdog.sh check <project> <issue> [--transcript <path>] [--since <ISO time>] [--now <epoch>]
#   watchdog.sh heartbeat [--silent <window>]
#
# `check` is a launcher's one-shot, stateless question about ONE unattended
# session: did it make progress within the no-progress limit? It kills nothing
# and writes nothing. `heartbeat` is the session's own explicit progress mark;
# `--silent <window>` (<N> or <N>m minutes, <N>s seconds) declares one gap of up
# to that long, ended by the next heartbeat.
#
#   0  ok
#   3  stalled no-progress limit=<L>s age=<A>s last=<source> at=<UTC time>[ silent-window=expired]
#   2  watchdog: usage: <message>
#   1  watchdog: error: <message>      cannot determine: never ok, never stalled
#
# Stdout carries exactly one line on exits 0 and 3 and nothing otherwise; every
# stderr line this script prints starts "watchdog: ".
#
# Progress is an mtime. The candidates, in the order that breaks a tie:
#   transcript           <path>, a file named <session id>.jsonl
#   subagent-transcript  the newest file under <path minus .jsonl>/
#   wrap, beat, dispatch, script
#                        this session's files under
#                        $(devagent_home)/state/watchdog/<session id>/
#   since                --since: the launch (or resume) time, for the seconds
#                        before the transcript exists
# The session is the one the transcript's name carries; CLAUDE_CODE_SESSION_ID
# is not read by `check`. Each candidate is allowed the limit; `beat` and a
# `wrap.<run>` are allowed max(limit, window) while their `.window` file holds
# seconds no greater than the silent-window maximum. A candidate more than 60 s
# ahead of now is not evidence and is dropped. `ok` when any candidate is within
# its allowance; otherwise `stalled`, naming the newest.
#
# --transcript absent: the path is read from DEVAGENT_WATCHDOG_TRANSCRIPT (the
# flag wins). Either goes through `cygpath -u` where that exists, so a Windows
# launcher may pass C:\...\<id>.jsonl.
#
# This script opts out of the script-entry heartbeat (a launcher's poll is not
# the session's progress), prints through its own helpers, and calls no library
# function that exits. It reads no devDoc path.

set -euo pipefail

_DEVAGENT_NO_ENTRY_BEAT=1

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/heartbeat.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/watchdog-limits.sh"

wd_usage() { echo "watchdog: usage: $*" >&2; exit 2; }
wd_error() { echo "watchdog: error: $*" >&2; exit 1; }
wd_warn()  { echo "watchdog: warning: $*" >&2; }

WD_SYNOPSIS_CHECK='watchdog.sh check <project> <issue> [--transcript <path>] [--since <ISO time>] [--now <epoch>]'
WD_SYNOPSIS_BEAT='watchdog.sh heartbeat [--silent <window>]'
WD_NAME_RE="$WATCHDOG_NAME_RE"
WD_NOW_RE='^[0-9]{1,12}$'
WD_FUTURE_SLACK=60
# The tie order: on equal times the earlier source is named.
WD_SOURCES="transcript subagent-transcript wrap beat dispatch script since"

# The candidates, as parallel arrays: time, allowance, source, and whether a
# valid silent window was read for it.
WD_TIME=() WD_ALLOW=() WD_SRC=() WD_WIN=()

wd_add() { WD_TIME+=("$1"); WD_ALLOW+=("$2"); WD_SRC+=("$3"); WD_WIN+=("${4:-0}"); }

# wd_rank <source> — sets WD_RANK to the source's place in the tie order.
wd_rank() {
  local s
  WD_RANK=0
  for s in $WD_SOURCES; do
    [[ "$s" != "$1" ]] || return 0
    WD_RANK=$((WD_RANK + 1))
  done
}

# wd_mtime <path> — sets WD_MTIME (epoch seconds); returns 1 when the file
# cannot be stat'ed.
wd_mtime() {
  WD_MTIME="$(stat -c %Y -- "$1" 2>/dev/null)" || { WD_MTIME=""; return 1; }
  WD_MTIME="${WD_MTIME//$'\r'/}"
  [[ "$WD_MTIME" =~ ^[0-9]+$ ]]
}

# wd_window <state file> <limit> <maximum> — sets WD_ALLOWANCE and WD_WINDOWED
# from <state file>.window. Only whole seconds in range and no greater than the
# maximum count; any other content, or no file, leaves the limit.
wd_window() {
  local w=""
  WD_ALLOWANCE="$2" WD_WINDOWED=0
  [[ -f "$1.window" ]] || return 0
  { IFS= read -r w < "$1.window"; } 2>/dev/null || true
  w="${w//$'\r'/}"
  watchdog_secs_ok "$w" || return 0
  (( 10#$w <= $3 )) || return 0
  WD_WINDOWED=1
  if (( 10#$w > $2 )); then WD_ALLOWANCE="$((10#$w))"; fi
  return 0
}

# wd_limit <key> <project> — sets WATCHDOG_LIMIT or exits 1: a malformed or
# unreadable limit is cannot-determine, never a default.
wd_limit() {
  local rc=0
  watchdog_limit "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) wd_error "$1 in [${WATCHDOG_LIMIT_SRC}] is not whole seconds from 1 to ${WATCHDOG_SECS_MAX}: cannot determine progress (doctor names the value)" ;;
    *) wd_error "cannot read $1 from the config at $(config_path): cannot determine progress" ;;
  esac
}

cmd_check() {
  local project issue transcript="" since="" now="" converted
  local -a pos=()
  while (( $# )); do
    case "$1" in
      --transcript|--since|--now)
        (( $# >= 2 )) || wd_usage "$1 needs a value; $WD_SYNOPSIS_CHECK"
        [[ -n "$2" ]] || wd_usage "$1 needs a non-empty value; $WD_SYNOPSIS_CHECK"
        case "$1" in
          --transcript) transcript="$2" ;;
          --since)      since="$2" ;;
          --now)        now="$2" ;;
        esac
        shift 2 ;;
      --*) wd_usage "unknown option $1; $WD_SYNOPSIS_CHECK" ;;
      *)   pos+=("$1"); shift ;;
    esac
  done
  (( ${#pos[@]} == 2 )) || wd_usage "check takes <project> and <issue>; $WD_SYNOPSIS_CHECK"
  project="${pos[0]}" issue="${pos[1]}"
  [[ "$project" =~ $WD_NAME_RE ]] || wd_usage "<project> must match $WD_NAME_RE"
  [[ "$issue" =~ $WD_NAME_RE ]] || wd_usage "<issue> must match $WD_NAME_RE"
  if [[ -n "$now" ]]; then
    [[ "$now" =~ $WD_NOW_RE ]] || wd_usage "--now must be epoch seconds matching $WD_NOW_RE"
    now="$((10#$now))"
  else
    printf -v now '%(%s)T' -1
  fi

  # The transcript: the flag, else the variable; never both.
  [[ -n "$transcript" ]] || transcript="${DEVAGENT_WATCHDOG_TRANSCRIPT:-}"
  [[ -n "$transcript" ]] || wd_usage "no transcript: pass --transcript <path> or set DEVAGENT_WATCHDOG_TRANSCRIPT"
  if command -v cygpath >/dev/null 2>&1; then
    converted="$(cygpath -u -- "$transcript" 2>/dev/null)" || converted=""
    [[ -z "$converted" ]] || transcript="$converted"
  fi
  local base="${transcript##*/}" stem
  stem="${base%.jsonl}"
  if [[ "$base" != *.jsonl ]] || ! [[ "$stem" =~ $HEARTBEAT_ID_RE ]]; then
    wd_usage "the transcript must be a file named <session id>.jsonl, the id a UUID; got '$base'"
  fi

  local since_epoch="" rc=0
  if [[ -n "$since" ]]; then
    watchdog_parse_since "$since" || rc=$?
    case "$rc" in
      0) since_epoch="$WATCHDOG_SINCE_EPOCH" ;;
      2) wd_usage "--since must be an ISO time with a zone, like 2026-11-20T18:35:00Z or 2026-11-20T19:35:00+01:00; got '$since'" ;;
      *) wd_error "python3 could not convert --since '$since': cannot determine progress" ;;
    esac
  fi

  # The project must be a table of the config. One read tells the three cases
  # apart: a table (the reader's rc 1 and its "is a table" text), absent (rc 1,
  # silent), and a config that cannot be read (rc 2 or more).
  local out
  rc=0
  out="$(_config_toml get "$(config_path)" "project.${project}" 2>&1)" || rc=$?
  case "$rc" in
    1) [[ "$out" == *"is a table, not a value"* ]] \
         || wd_error "project '$project' is not in the config at $(config_path)" ;;
    0) wd_error "project '$project' is not a table in the config at $(config_path)" ;;
    *) wd_error "cannot read the config at $(config_path): cannot determine progress" ;;
  esac

  local limit max
  wd_limit watchdog_no_progress_secs "$project"
  limit="$WATCHDOG_LIMIT"
  wd_limit watchdog_silent_max_secs ""
  max="$WATCHDOG_LIMIT"

  heartbeat_dir_for "$stem" || wd_error "cannot name the state directory for session $stem"
  local id="$HEARTBEAT_ID" dir="$HEARTBEAT_DIR"

  # A session dispatched for another issue is not the one being asked about. An
  # empty record (a writer between its truncate and its line) and a record of a
  # later version say nothing either way.
  if [[ -f "$dir/dispatch" ]]; then
    local d_ver="" d_project="" d_issue=""
    { read -r d_ver d_project d_issue _ < "$dir/dispatch"; } 2>/dev/null || true
    d_issue="${d_issue//$'\r'/}"
    if [[ "$d_ver" == v1 && -n "$d_project" && -n "$d_issue" ]] \
       && [[ "$d_project" != "$project" || "$d_issue" != "$issue" ]]; then
      wd_error "session $id was last dispatched for $d_project $d_issue, not $project $issue: cannot determine progress"
    fi
  fi

  # Candidates. The transcript first.
  if [[ -e "$transcript" ]]; then
    wd_mtime "$transcript" || wd_error "cannot stat the transcript $transcript: cannot determine progress"
    wd_add "$WD_MTIME" "$limit" transcript
  elif [[ -z "$since_epoch" ]]; then
    wd_error "no transcript at $transcript and no --since: cannot determine progress (pass --since <launch time> until the transcript exists)"
  fi

  # The newest file under the session's own transcript directory: subagents
  # write there while the parent's file stands still. A file that vanishes
  # between the listing and its stat is skipped; a listing that failed and
  # gave no time at all cannot tell progress from silence.
  local sub="${transcript%.jsonl}" t newest="" listing lrc
  if [[ -d "$sub" ]]; then
    lrc=0
    listing="$(find "$sub" -type f -printf '%T@\n' 2>/dev/null)" || lrc=$?
    while IFS= read -r t; do
      t="${t//$'\r'/}" t="${t%%.*}"
      [[ "$t" =~ ^[0-9]+$ ]] || continue
      if [[ -z "$newest" ]] || (( t > newest )); then newest="$t"; fi
    done <<<"$listing"
    if [[ -n "$newest" ]]; then
      wd_add "$newest" "$limit" subagent-transcript
    elif (( lrc != 0 )); then
      wd_error "cannot list $sub: cannot determine progress"
    fi
  fi

  # This session's state files, and no other session's. One stat for all.
  local f name line
  local -a files=()
  if [[ -d "$dir" ]]; then
    for f in "$dir"/wrap.* "$dir/beat" "$dir/dispatch" "$dir/script"; do
      [[ -f "$f" && "$f" != *.window ]] || continue
      files+=("$f")
    done
  fi
  if (( ${#files[@]} )); then
    local parsed=0
    lrc=0
    listing="$(stat -c '%Y %n' -- "${files[@]}" 2>/dev/null)" || lrc=$?
    while IFS= read -r line; do
      line="${line//$'\r'/}"
      t="${line%% *}" f="${line#* }"
      [[ "$t" =~ ^[0-9]+$ ]] || continue
      parsed=$((parsed + 1))
      name="${f##*/}"
      case "$name" in
        wrap.*|beat) wd_window "$f" "$limit" "$max"; wd_add "$t" "$WD_ALLOWANCE" "${name%%.*}" "$WD_WINDOWED" ;;
        *)           wd_add "$t" "$limit" "$name" ;;
      esac
    done <<<"$listing"
    (( parsed > 0 || lrc == 0 )) || wd_error "cannot stat the state files in $dir: cannot determine progress"
  fi

  [[ -z "$since_epoch" ]] || wd_add "$since_epoch" "$limit" since

  # Judge. A time more than the slack ahead of now is dropped.
  local i kept=0 best=-1 best_rank=0
  for i in "${!WD_TIME[@]}"; do
    t="${WD_TIME[$i]}"
    (( t <= now + WD_FUTURE_SLACK )) || continue
    kept=$((kept + 1))
    if (( now - t <= WD_ALLOW[i] )); then
      echo ok
      exit 0
    fi
    wd_rank "${WD_SRC[$i]}"
    if (( best < 0 )) || (( t > WD_TIME[best] )) \
       || { (( t == WD_TIME[best] )) && (( WD_RANK < best_rank )); }; then
      best="$i" best_rank="$WD_RANK"
    fi
  done
  (( kept > 0 )) || wd_error "every progress time for session $id is more than ${WD_FUTURE_SLACK} s ahead of now ($now): cannot determine progress"

  local at tail=""
  TZ=UTC0 printf -v at '%(%Y-%m-%dT%H:%M:%SZ)T' "${WD_TIME[$best]}"
  (( WD_WIN[best] == 0 )) || tail=" silent-window=expired"
  echo "stalled no-progress limit=${limit}s age=$((now - WD_TIME[best]))s last=${WD_SRC[$best]} at=${at}${tail}"
  exit 3
}

cmd_heartbeat() {
  local silent="" have_silent=0 rc=0
  while (( $# )); do
    case "$1" in
      --silent)
        (( $# >= 2 )) || wd_usage "--silent needs a window; $WD_SYNOPSIS_BEAT"
        [[ -n "$2" ]] || wd_usage "--silent needs a non-empty window; $WD_SYNOPSIS_BEAT"
        silent="$2" have_silent=1
        shift 2 ;;
      *) wd_usage "unknown argument $1; $WD_SYNOPSIS_BEAT" ;;
    esac
  done

  # The window is judged before anything is written, marker or not.
  if (( have_silent )); then
    # A heartbeat never fails a run over the config.
    watchdog_window_or_shipped "$silent" || rc=$?
    [[ -z "$WATCHDOG_WINDOW_NOTE" ]] || wd_warn "$WATCHDOG_WINDOW_NOTE"
    (( rc == 0 )) || wd_usage "$WATCHDOG_WINDOW_ERR"
    # The window first: a check between the two writes sees an old beat with a
    # window, never a fresh beat the window has not reached.
    heartbeat_note beat.window "$WATCHDOG_WINDOW_SECS"
    heartbeat_touch beat
  else
    heartbeat_touch beat
    heartbeat_drop beat.window
  fi
  echo ok
  exit 0
}

case "${1:-}" in
  check)     shift; cmd_check "$@" ;;
  heartbeat) shift; cmd_heartbeat "$@" ;;
  "")        wd_usage "$WD_SYNOPSIS_CHECK | $WD_SYNOPSIS_BEAT" ;;
  *)         wd_usage "unknown command $1; $WD_SYNOPSIS_CHECK | $WD_SYNOPSIS_BEAT" ;;
esac
