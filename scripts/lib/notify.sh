#!/usr/bin/env bash
# scripts/lib/notify.sh — the launcher notifications file and its ONE appender (#961).
#
#   sourced:  notify_append <key>=<value>...   append one line
#             notify_check  <key>=<value>...   the same checks, writes nothing
#   executed: notify.sh --check <key>=<value>...
#             notify.sh --rotate <new-name>     rename the file under the lock
#
# Keys: event project issue capture step question detail. The file is
# $(devagent_home)/state/notifications.jsonl, one JSON object per line; the
# format, the events and the exit table are the launcher contract in spec §7.3.
#
# This file does only what must happen in bash: it refuses a value holding a
# newline or CR, converts the question path with `cygpath -m` on Git Bash, and
# hands the fields to scripts/lib/_notify.py on STDIN (never argv or the
# environment, which Git Bash rewrites). The helper owns every other refusal,
# the line format, the lock and the write.
#
# Exits: 0 written; 2 refused (`notify: refused (<id>): ...`); 3 lock timeout;
# 4 I/O; 5 `--rotate` found no file (`notify: nothing-to-rotate`). The functions
# RETURN their status and never exit; diagnostics go to stderr and stdout stays
# empty. Sourcing changes no shell option and prints nothing.
# shellcheck shell=bash

_NOTIFY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NOTIFY_PY="$_NOTIFY_LIB/_notify.py"
# shellcheck source=scripts/lib/paths.sh
. "$_NOTIFY_LIB/paths.sh"
# The capture rule is the real devagent_validate_slug, never a copy of it.
# shellcheck source=scripts/capture/lib/paths.sh
[ -r "$_NOTIFY_LIB/../capture/lib/paths.sh" ] && . "$_NOTIFY_LIB/../capture/lib/paths.sh"
if [ "$(type -t devagent_validate_slug)" != function ]; then
  printf 'notify: io: devagent_validate_slug unavailable\n' >&2
  return 1 2>/dev/null || exit 4
fi

# _notify_io <what>: print the I/O diagnostic. Callers return 4.
_notify_io() { printf 'notify: io: %s\n' "$1" >&2; }

# _notify_refuse <id> <rule>: print a refusal. Callers return 2. The rule never
# repeats a field value.
_notify_refuse() { printf 'notify: refused (%s): %s\n' "$1" "$2" >&2; }

# _notify_native <path>: print <path> in the native form a Windows python reads
# (`cygpath -m`) when cygpath exists, else unchanged. Returns non-zero when the
# conversion fails. `--` keeps a dash-led value from reading as an option, and
# cygpath's stderr is dropped, since it can echo the value.
_notify_native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m -- "$1" 2>/dev/null
  else
    printf '%s\n' "$1"
  fi
}

# _notify_helper <mode> [<arg>]: run the helper with the state directory and,
# for append and check, the config path (which replaces <arg>); the fields come
# on stdin. When cygpath exists, the helper, state and config paths go through
# ONE `cygpath -m` call, which prints one path per line (a fork is slow on Git
# Bash). MSYS path conversion is off, so every argument arrives as written.
_notify_helper() {
  local mode="$1" out home cfg
  local -a paths conv
  shift
  command -v python3 >/dev/null 2>&1 || { _notify_io "no python3 on PATH"; return 4; }
  [ -f "$_NOTIFY_PY" ] && [ -r "$_NOTIFY_PY" ] || { _notify_io "helper _notify.py is not readable"; return 4; }
  home="$(devagent_home)" || { _notify_io "cannot resolve the devagent home"; return 4; }
  paths=("$_NOTIFY_PY" "$home/state")
  case "$mode" in
    append|check)
      cfg="$(config_path)" || { _notify_io "cannot resolve the config path"; return 4; }
      paths+=("$cfg")
      ;;
  esac
  if command -v cygpath >/dev/null 2>&1; then
    out="$(cygpath -m -- "${paths[@]}")" || { _notify_io "cygpath failed on the helper, state or config path"; return 4; }
    mapfile -t conv <<< "$out"
    [ "${#conv[@]}" -eq "${#paths[@]}" ] || { _notify_io "cygpath printed ${#conv[@]} paths for ${#paths[@]}"; return 4; }
    paths=("${conv[@]}")
  fi
  # append and check: the (converted) config path is the helper's third argument.
  if [ "${#paths[@]}" -eq 3 ]; then set -- "${paths[2]}"; fi
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python3 -X utf8 "${paths[0]}" "$mode" "${paths[1]}" "$@"
}

# _notify_run <append|check> <key>=<value>...: the bash half of both doors.
_notify_run() {
  local mode="$1" a k v fields=""
  shift
  [ "$#" -gt 0 ] || { _notify_refuse framing "no fields given"; return 2; }
  for a in "$@"; do
    case "$a" in
      *$'\n'*|*$'\r'*) _notify_refuse newline "a value holds a newline or CR"; return 2 ;;
    esac
  done
  for a in "$@"; do
    k="${a%%=*}"
    v="${a#*=}"
    if [ "$k" = question ] && [ "$a" != "$k" ] && [ -n "$v" ]; then
      v="$(_notify_native "$v")" || { _notify_io "cygpath failed on the question path"; return 4; }
      case "$v" in
        *$'\n'*|*$'\r'*) _notify_refuse newline "the converted question holds a newline or CR"; return 2 ;;
      esac
      a="question=$v"
    fi
    # The validator's stderr echoes the slug; this message never does.
    if [ "$k" = capture ] && [ "$a" != "$k" ] && ! devagent_validate_slug "$v" 2>/dev/null; then
      _notify_refuse capture "capture is not a valid capture slug"
      return 2
    fi
    fields+="$a"$'\n'
  done
  _notify_helper "$mode" <<< "${fields%$'\n'}"
}

notify_append() { _notify_run append "$@"; }
notify_check() { _notify_run check "$@"; }

_NOTIFY_USAGE='notify.sh --check <key>=<value>... | notify.sh --rotate <new-name>'

# _notify_main <args...>: the executed grammar. Anything else is usage (exit 2).
_notify_main() {
  local a
  case "${1:-}" in
    --check)
      shift
      [ "$#" -gt 0 ] || { _notify_refuse usage "$_NOTIFY_USAGE"; return 2; }
      for a in "$@"; do
        case "$a" in
          ''|-*) _notify_refuse usage "$_NOTIFY_USAGE"; return 2 ;;
        esac
      done
      _notify_run check "$@"
      ;;
    --rotate)
      [ "$#" -eq 2 ] || { _notify_refuse usage "$_NOTIFY_USAGE"; return 2; }
      case "$2" in
        -*) _notify_refuse usage "$_NOTIFY_USAGE"; return 2 ;;
        *$'\n'*|*$'\r'*) _notify_refuse newline "the new name holds a newline or CR"; return 2 ;;
      esac
      _notify_helper rotate "$2"
      ;;
    *)
      _notify_refuse usage "$_NOTIFY_USAGE"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _notify_main "$@"
  exit $?
fi
