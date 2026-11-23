#!/usr/bin/env bash
# libexec/long-run.sh — #932: run one long command so that its output counts as
# the session's progress.
#
#   long-run.sh [--silent <window>] [--merge] [--project <name>] [--every <secs>]
#               [--log-cap <bytes>] [--] <command> [<arg>...]
#
# The command runs with its own stdin, and its output reaches the caller
# unchanged, byte for byte and as it is written; the exit code is the
# command's. In an unattended session (scripts/lib/paths.sh: devagent_unattended)
# whose CLAUDE_CODE_SESSION_ID is a UUID, a byte pump in the data path
# (scripts/lib/_longrun_pump.py) moves the run's heartbeat file for the bytes it
# carries, and `watchdog.sh check` reads that file as progress. Nothing is
# killed, nothing is written to devDoc, and an attended run differs only by the
# log it leaves.
#
#   --silent <window>  the command may print nothing for up to <window> (<N> or
#                      <N>m minutes, <N>s seconds): `check` allows this run
#                      max(limit, window) per gap for as long as it lives. A
#                      window above the operator's maximum is refused, exit 2,
#                      before the command starts.
#   --merge            the caller reads both streams as one (it would have
#                      written 2>&1): the command's stderr joins its stdout in
#                      one pipe, so their order stays the command's own.
#                      Without it the streams stay separate, each through its
#                      own pump.
#   --project <name>   the project whose watchdog_telemetry_secs is the `quiet`
#                      threshold; else DEVAGENT_ACTIVE_PROJECT; else [defaults].
#   --every <secs>     0..9999, default 5: the heartbeat moves at most this
#                      often; 0 = for every chunk.
#   --log-cap <bytes>  1000000..9999999999, default 5242880: the size no log
#                      file passes; at the cap a log moves to `<log>.1`.
#
# Options end at `--` or at the first word that does not start with `--`.
# Leading NAME=value words are the command's environment (it runs through
# `env`). The command is a program, found on PATH: a shell function, builtin,
# pipeline, `cd … &&` chain or loop goes in as  bash -c '<the whole line>'.
# It must finish: the wrapper returns when the command and everything that
# still holds its output have ended.
#
#   exit  the command's own code (127: not found; 126: not runnable)
#         2  long-run: usage: <message>     before the command starts
#
# Every line this script prints itself goes to stderr and starts "long-run: ";
# none enters the command's streams.
#
# State, all under $(devagent_home)/state/watchdog/ (scripts/lib/heartbeat.sh).
# <run> is <start epoch>-<this script's pid>.
#
#   <id>/wrap.<run>          empty; mtime = the run's last output (its start,
#                            until it prints). Stays after the run, as ordinary
#                            progress.
#   <id>/wrap.<run>.window   "<seconds>"; only with --silent, only while the run
#                            lives. A killed wrapper leaves it; it then expires
#                            by its own age.
#   logs/<id>.<run>.log      --merge: the one stream
#   logs/<id>.<run>.out.log  two streams: stdout …
#   logs/<id>.<run>.err.log  … and stderr
#   logs/no-session.<run>.log, .out.log, .err.log
#                            the same, for an attended run or one without a
#                            valid session id
#   <log>.1                  the log's previous <cap> bytes
#
# One writer per log file: a pump owns its file while the command runs (two
# appenders to one file lose lines on Windows), and this script writes to it
# only before the pumps start and after they end. So every log of a run reads
# alone: first line `start`, then that stream's bytes with the pump's `quiet`
# lines where a gap ended, the pump's `closed` line, last line `end` — in the
# one log with --merge, in BOTH the .out.log and the .err.log without it.
#
#   [long-run] start <ISO-UTC> run=<run> cmd=<command basename>
#   [long-run] quiet <gap>s > <threshold>s ended <ISO-UTC> run=<run>
#   [long-run] closed <stdout|stderr|merged> <ISO-UTC> run=<run> longest-gap=<gap>s refreshes=<n>
#   [long-run] end <ISO-UTC> run=<run> rc=<rc>
#
# Retention: at each start, best-effort, log files older than 14 days and
# session directories (<id>/) with nothing newer than 14 days are removed.
#
# This script never fails a run. A limit it cannot read is the shipped constant
# and one warning; without a python3 that runs, the command runs unwrapped
# after one warning. It opts out of the script-entry heartbeat (its own start
# is not progress; the command's output is) by a variable it does NOT export:
# a devagent script run as the command still counts its own entry.
#
# It lives outside scripts/ on purpose: every command and skill grants
# `bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *`, and a wrapper that runs any
# command must not ride that grant. A launcher that wants it auto-approved
# grants it by name, which is the same as allowing every command. Claude Code
# matches Bash rules on the text without resolving `..` (measured 2026-11-23,
# 2.1.330: `bash "<root>/scripts/../libexec/long-run.sh" …` ran under the
# skills' grant alone), so a path to this file with a `.` or `..` segment is
# refused before anything runs.

set -u

_lr_self="${BASH_SOURCE[0]//\\//}"
case "$_lr_self" in
  */../*|*/./*)
    echo "long-run: refused: run this wrapper by its own path, without '.' or '..' segments (got ${BASH_SOURCE[0]})" >&2
    exit 2 ;;
esac

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

lr_usage() { echo "long-run: usage: $*" >&2; exit 2; }
lr_warn()  { echo "long-run: warning: $*" >&2; }

LR_SYNOPSIS='long-run.sh [--silent <window>] [--merge] [--project <name>] [--every <secs>] [--log-cap <bytes>] [--] <command> [<arg>...]'
LR_EVERY_RE='^[0-9]{1,4}$'
LR_CAP_RE='^[1-9][0-9]{6,9}$'
LR_NAME_RE="$WATCHDOG_NAME_RE"
LR_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='
LR_KEEP_DAYS=14

# ---------------------------------------------------------------- arguments

silent="" merge=0 project="" every=5 cap=5242880
while (( $# )); do
  case "$1" in
    --) shift; break ;;
    --merge) merge=1; shift ;;
    --silent|--project|--every|--log-cap)
      (( $# >= 2 )) || lr_usage "$1 needs a value; $LR_SYNOPSIS"
      [[ -n "$2" ]] || lr_usage "$1 needs a non-empty value; $LR_SYNOPSIS"
      case "$1" in
        --silent)  silent="$2" ;;
        --project) [[ "$2" =~ $LR_NAME_RE ]] || lr_usage "--project must match $LR_NAME_RE"
                   project="$2" ;;
        --every)   [[ "$2" =~ $LR_EVERY_RE ]] || lr_usage "--every must be seconds matching $LR_EVERY_RE (0 = every chunk)"
                   every="$((10#$2))" ;;
        --log-cap) [[ "$2" =~ $LR_CAP_RE ]] || lr_usage "--log-cap must be bytes matching $LR_CAP_RE (1000000 or more)"
                   cap="$((10#$2))" ;;
      esac
      shift 2 ;;
    --*) lr_usage "unknown option $1; $LR_SYNOPSIS" ;;
    *) break ;;
  esac
done

# The command: leading NAME=value words make it an `env` call. Its name, for
# the log, is the first word that is not one.
cmd=("$@")
name=""
for word in "$@"; do
  [[ "$word" =~ $LR_ASSIGN_RE ]] || { name="$word"; break; }
done
[[ -n "$name" ]] || lr_usage "no command; $LR_SYNOPSIS"
[[ "${cmd[0]}" == "$name" ]] || cmd=(env "$@")
name="${name##*/}"
name="${name//[^A-Za-z0-9._+-]/?}"
name="${name:0:64}"

if [[ -z "$project" && "${DEVAGENT_ACTIVE_PROJECT:-}" =~ $LR_NAME_RE ]]; then
  project="$DEVAGENT_ACTIVE_PROJECT"
fi

# ---------------------------------------------------------------- the run's record

printf -v started '%(%s)T' -1
run="${started}-$$"

# lr_iso — sets LR_ISO to now, UTC.
lr_iso() { TZ=UTC0 printf -v LR_ISO '%(%Y-%m-%dT%H:%M:%SZ)T' -1; }

watched=0 hb_file="" stem="no-session.${run}"
if heartbeat_dir; then
  watched=1
  hb_file="${HEARTBEAT_DIR}/wrap.${run}"
  stem="${HEARTBEAT_ID}.${run}"
fi
log_dir=""
! heartbeat_log_dir || log_dir="$HEARTBEAT_LOG_DIR"

# python3 runs the config reader and the pump. The paths the pump opens go to
# it in the form a native python reads (the notify.sh rule): one cygpath call
# where it exists.
python=1
command -v python3 >/dev/null 2>&1 || python=0
pump="$PLUGIN_ROOT/scripts/lib/_longrun_pump.py"
pump_log_dir="$log_dir" pump_hb="$hb_file"
if (( python )) && command -v cygpath >/dev/null 2>&1; then
  conv=()
  while IFS= read -r line; do conv+=("${line//$'\r'/}"); done \
    < <(cygpath -m -- "$pump" "${log_dir:-/}" "${hb_file:-/}" 2>/dev/null)
  if (( ${#conv[@]} == 3 )); then
    pump="${conv[0]}"
    [[ -z "$log_dir" ]] || pump_log_dir="${conv[1]}"
    [[ -z "$hb_file" ]] || pump_hb="${conv[2]}"
  fi
fi
# A python3 that is found but cannot run the pump would swallow the command's
# output, so it is asked once, before anything depends on it.
if (( python )); then
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python3 -I -B "$pump" --probe >/dev/null 2>&1 || python=0
fi
(( python )) || lr_warn "no python3 that runs the pump; the command runs unwrapped: its output is not logged and does not count as progress"

# The window is judged before anything is written or run, marker or not.
window=""
if [[ -n "$silent" ]]; then
  rc=0
  if (( python )); then
    watchdog_window_or_shipped "$silent" "$project" || rc=$?
    [[ -z "$WATCHDOG_WINDOW_NOTE" ]] || lr_warn "$WATCHDOG_WINDOW_NOTE"
  else
    # No config reader: the shipped maximum, under the warning above.
    watchdog_window "$silent" "" "$WATCHDOG_DEFAULT_SILENT_MAX_SECS" || rc=$?
  fi
  (( rc == 0 )) || lr_usage "$WATCHDOG_WINDOW_ERR"
  window="$WATCHDOG_WINDOW_SECS"
fi

# The `quiet` threshold: the interval, or the window when that is larger. Only
# a watched run has one.
threshold=0
if (( watched && python )); then
  rc=0
  watchdog_limit watchdog_telemetry_secs "$project" || rc=$?
  if (( rc == 0 )); then
    threshold="$WATCHDOG_LIMIT"
  else
    threshold="$WATCHDOG_DEFAULT_TELEMETRY_SECS"
    lr_warn "watchdog_telemetry_secs could not be read${project:+ for $project} (doctor names the value); a gap is noted as quiet above ${threshold} s"
  fi
  if [[ -n "$window" ]] && (( window > threshold )); then threshold="$window"; fi
fi

# lr_prune — retention, best-effort and silent. ONE listing (GNU find, like the
# `stat -c` of watchdog.sh) gives every entry's mtime, and only what that
# listing shows as old is removed: a log or a directory another run creates
# after it is never a candidate. Ours are the files under logs/ and the
# directories named like a session id; a directory goes when it and everything
# in it are old; this session's own directory is never touched. A `find` that
# fails prunes nothing.
lr_prune() {
  local root="${HEARTBEAT_ROOT:-}" listing line t rel top cutoff
  [[ -n "$root" && -d "$root" ]] || return 0
  listing="$(find "$root" -mindepth 1 -maxdepth 2 -printf '%T@ %P\n' 2>/dev/null)" || return 0
  cutoff="$(( started - LR_KEEP_DAYS * 86400 ))"
  local -A young=()
  local -a tops=() dead_logs=() dead_dirs=()
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    t="${line%% *}"
    t="${t%%.*}"
    rel="${line#* }"
    [[ "$t" =~ ^[0-9]{1,12}$ && -n "$rel" ]] || continue
    top="${rel%%/*}"
    if [[ "$rel" == "$top" ]]; then tops+=("$top"); fi
    if (( 10#$t >= cutoff )); then
      young["$top"]=1
    elif [[ "$rel" == logs/* ]]; then
      dead_logs+=("$root/$rel")
    fi
  done <<<"$listing"
  if (( ${#tops[@]} )); then
    for top in "${tops[@]}"; do
      [[ "$top" =~ ${HEARTBEAT_ID_RE:-^$} && "$top" == "${top,,}" ]] || continue
      [[ "$top" != "${HEARTBEAT_ID:-}" && -z "${young["$top"]:-}" ]] || continue
      dead_dirs+=("$root/$top")
    done
  fi
  (( ${#dead_logs[@]} == 0 )) || rm -f -- "${dead_logs[@]}" 2>/dev/null || true
  (( ${#dead_dirs[@]} == 0 )) || rm -rf -- "${dead_dirs[@]}" 2>/dev/null || true
}
lr_prune

# The window first: a check between the two writes sees a window with no file
# yet, never a fresh file the window has not reached.
if (( watched )); then
  [[ -z "$window" ]] || heartbeat_note "wrap.${run}.window" "$window"
  heartbeat_touch "wrap.${run}"
fi

# A log holds the command's whole output, so the directory is 0700 and each
# log 0600 (the pump creates a rotated log 0600 too). Only logs/ itself needs
# the mode: its parents hold no output.
# shellcheck disable=SC2174
if [[ -n "$log_dir" && ! -d "$log_dir" ]] && ! mkdir -p -m 700 "$log_dir" 2>/dev/null; then
  lr_warn "cannot create $log_dir; this run keeps no log"
  log_dir="" pump_log_dir=""
fi

# lr_pump <stream> <log suffix> — exec the pump for one stream. The MSYS
# variables keep its arguments from being rewritten as paths.
lr_pump() {
  local log=""
  [[ -z "$pump_log_dir" ]] || log="${pump_log_dir}/${stem}.$2"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' exec python3 -I -B "$pump" \
    "$1" "$log" "$cap" "$pump_hb" "$every" "$threshold" "$run"
}

# lr_note <text> — one line in each log of this run. Called only while no pump
# is running.
logs=()
if [[ -n "$log_dir" ]] && (( python )); then
  if (( merge )); then
    logs=("$log_dir/${stem}.log")
  else
    logs=("$log_dir/${stem}.out.log" "$log_dir/${stem}.err.log")
  fi
fi
lr_note() {
  local f
  (( ${#logs[@]} )) || return 0
  for f in "${logs[@]}"; do
    if [[ -e "$f" ]]; then
      { printf '%s\n' "$1" >> "$f"; } 2>/dev/null || true
    else
      ( umask 077; printf '%s\n' "$1" >> "$f" ) 2>/dev/null || true
    fi
  done
}

lr_iso
lr_note "[long-run] start ${LR_ISO} run=${run} cmd=${name}"

# ---------------------------------------------------------------- the command

# `exec` in each pipeline element: the command replaces its subshell, so it is
# a program (never one of this script's functions) and its exit code is the
# element's own.
rc=0
if (( ! python )) && (( merge )); then
  # Unpumped, but a merged caller still gets one stream.
  ( exec "${cmd[@]}" 2>&1 ) || rc=$?
elif (( ! python )); then
  ( exec "${cmd[@]}" ) || rc=$?
elif (( merge )); then
  # One pipe carries both streams, so their order stays the command's.
  { exec "${cmd[@]}" 2>&1; } | lr_pump merged log
  rc="${PIPESTATUS[0]}"
elif exec {lr_out}>&1 {lr_err}>&2; then
  # Two pumps in nested pipelines (process substitution loses output on Git
  # Bash: Issue-932 R2-U1). The caller's stdout and stderr are saved on two
  # spare descriptors of bash's choosing (the caller's own low ones stay the
  # command's), closed for the command; the inner pump writes the command's
  # stdout to the first, the outer one its stderr to the second. The pipeline
  # returns when both pumps have ended.
  {
    { exec "${cmd[@]}" {lr_out}>&- {lr_err}>&-; } \
      | lr_pump stdout out.log >&"$lr_out" {lr_out}>&- {lr_err}>&-
    exit "${PIPESTATUS[0]}"
  } 2>&1 | lr_pump stderr err.log >&"$lr_err" {lr_out}>&- {lr_err}>&-
  rc="${PIPESTATUS[0]}"
  exec {lr_out}>&- {lr_err}>&-
else
  # The caller closed stdout or stderr: there is nothing to pump to.
  lr_warn "stdout or stderr is closed; the command runs unwrapped"
  ( exec "${cmd[@]}" ) || rc=$?
fi

lr_iso
lr_note "[long-run] end ${LR_ISO} run=${run} rc=${rc}"
(( ! watched )) || [[ -z "$window" ]] || heartbeat_drop "wrap.${run}.window"
exit "$rc"
