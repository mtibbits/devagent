#!/usr/bin/env bash
# scripts/lib/heartbeat.sh — #932: the per-session progress record a launcher's
# `watchdog.sh check` reads. One file per progress source in one directory per
# session; progress is the file's mtime, moved by a builtin redirect:
#
#   $(devagent_home)/state/watchdog/<id>/<name>      <id> = the session id, lower-cased
#   $(devagent_home)/state/watchdog/logs/            the wrapper's logs
#
# Requires paths.sh sourced first (devagent_home, devagent_unattended). Sourced
# without it, every function is a silent no-op: this file never sources paths.sh,
# so paths.sh may source it from its own tail.
#
# Sourcing defines functions and three variables, sets no shell option, reads no
# config, and forks once (devagent_home, so the DA_HOME rule keeps its one home).
# The root is fixed at source time; the session id is read on every call. Every
# expansion is defaulted, so a `set -u` caller is safe. The id test is a regex
# match, so a call replaces the caller's BASH_REMATCH.
#
# Writers (heartbeat_touch, heartbeat_note, heartbeat_drop) always return 0 and
# print nothing on stdout. They write only when devagent_unattended holds and
# CLAUDE_CODE_SESSION_ID is a UUID; otherwise they do nothing, silently.
# Queries (heartbeat_dir, heartbeat_dir_for, heartbeat_log_dir) return 1,
# silently, when they have no answer.

# The session id, and the stem of a transcript's file name.
# shellcheck disable=SC2034  # also read by watchdog.sh
HEARTBEAT_ID_RE='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

# The state root, once per process. Empty when it cannot be known.
HEARTBEAT_ROOT=""
if declare -F devagent_home >/dev/null 2>&1; then
  HEARTBEAT_ROOT="$(devagent_home 2>/dev/null)" || HEARTBEAT_ROOT=""
  [[ -z "${HEARTBEAT_ROOT:-}" ]] || HEARTBEAT_ROOT="${HEARTBEAT_ROOT}/state/watchdog"
fi

# heartbeat_dir_for <id> — sets HEARTBEAT_ID (lower-cased) and HEARTBEAT_DIR for
# that session, whatever this process's own session is. Returns 1 when the id is
# not a UUID or the root is unknown. `check` names another session through this.
heartbeat_dir_for() {
  local _hb_id="${1:-}"
  HEARTBEAT_ID="" HEARTBEAT_DIR=""
  [[ -n "${HEARTBEAT_ROOT:-}" ]] || return 1
  [[ "$_hb_id" =~ ${HEARTBEAT_ID_RE:-^$} ]] || return 1
  HEARTBEAT_ID="${_hb_id,,}"
  HEARTBEAT_DIR="${HEARTBEAT_ROOT}/${HEARTBEAT_ID}"
}

# heartbeat_dir — this session's directory: heartbeat_dir_for the id in
# CLAUDE_CODE_SESSION_ID, and only in an unattended session.
heartbeat_dir() {
  HEARTBEAT_ID="" HEARTBEAT_DIR=""
  declare -F devagent_unattended >/dev/null 2>&1 || return 1
  devagent_unattended || return 1
  heartbeat_dir_for "${CLAUDE_CODE_SESSION_ID:-}"
}

# heartbeat_log_dir — sets HEARTBEAT_LOG_DIR. Attended runs log too, so this asks
# for neither the marker nor an id. Returns 1 when the root is unknown.
heartbeat_log_dir() {
  HEARTBEAT_LOG_DIR=""
  [[ -n "${HEARTBEAT_ROOT:-}" ]] || return 1
  HEARTBEAT_LOG_DIR="${HEARTBEAT_ROOT}/logs"
}

# _heartbeat_put <name> <mode> [<line>] — mode `touch` empties the file (which
# moves its mtime), mode `note` writes <line>. One retry after mkdir -p; a second
# failure prints one warning. `true`, not `:`, carries the redirect: a failed
# redirect on a special builtin ends a POSIX-mode shell.
_heartbeat_put() {
  local _hb_name="${1:-}" _hb_mode="${2:-touch}" _hb_line="${3:-}" _hb_path _hb_try
  case "$_hb_name" in ''|.*|*/*) return 0 ;; esac
  heartbeat_dir || return 0
  _hb_path="${HEARTBEAT_DIR}/${_hb_name}"
  for _hb_try in 1 2; do
    if [[ "$_hb_mode" == note ]]; then
      { printf '%s\n' "$_hb_line" > "$_hb_path"; } 2>/dev/null && return 0
    else
      { true > "$_hb_path"; } 2>/dev/null && return 0
    fi
    [[ "$_hb_try" == 1 ]] || break
    mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || true
  done
  echo "heartbeat: warning: cannot write $_hb_path" >&2
  return 0
}

# heartbeat_touch <name> — move <name>'s mtime to now, creating it empty.
heartbeat_touch() { _heartbeat_put "${1:-}" touch || true; return 0; }

# heartbeat_note <name> <line> — replace <name> with the one line.
heartbeat_note() { _heartbeat_put "${1:-}" note "${2:-}" || true; return 0; }

# heartbeat_drop <name> — remove <name>; absent is fine.
heartbeat_drop() {
  local _hb_name="${1:-}"
  case "$_hb_name" in ''|.*|*/*) return 0 ;; esac
  heartbeat_dir || return 0
  rm -f "${HEARTBEAT_DIR}/${_hb_name}" 2>/dev/null || true
  return 0
}
