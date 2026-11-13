#!/usr/bin/env bash
# scripts/issue/disk.sh — the disk issue backend (#1009, epic #1007).
# Answers the backend contract of spec §9.1 from `<N>.md` files in one folder,
# with no account and no network. Selected with `backend = "disk"` under
# [project.<name>.issue_source]; its `repo` is the issues folder, by an
# absolute path (`/…`, `~/…`; under Git Bash also `C:/…` and `C:\…`).
#
# Every read and write of an issue file goes through the format module,
# scripts/lib/disk-issue.py (#1008; docs/disk-issues.md). This script never
# reads or writes an issue file's bytes itself: bash touches only the folder
# listing (for numbering), `.last-number` and the `.disk.lock` folder lock.
# Each verb checks the folder, cds into it and hands the module bare `<N>.md`
# names, so no message names the folder: messages can land in the checklist
# log, and the devdoc may be pushed. They name the config key
# `issue_source.repo` instead.
#
# Exit codes, per verb (exit 2 means wrong arguments only: a caller reads it
# as "this backend has no such verb", so a folder fault is never 2):
#   fetch, state, comment-list
#       exit 0: ok; exit 1: folder fault; exit 2: wrong arguments;
#       exit 4: no <N>.md; exit 5: the file fails the format check
#   create
#       exit 0: ok; exit 1: folder fault, or out of numbers;
#       exit 2: wrong arguments, missing body file, or a prompt the format refuses
#   transition
#       exit 0: ok, or already there; exit 1: folder fault;
#       exit 2: wrong arguments, or the quarantine stage; exit 4: no <N>.md;
#       exit 5: the file fails the format check, and it is not rewritten
#   state-list, issue-list
#       exit 0: ok; exit 1: folder fault, or no folder argument;
#       exit 5: a file fails the format check (never exit 2)
#   state-class
#       exit 0: ok; exit 1: folder fault, or wrong arguments; exit 4: no <N>.md;
#       exit 5: the file fails the format check (never exit 2)
#   state-exists
#       exit 0: the status exists; exit 1: folder fault; exit 2: wrong arguments
#   events, events --kinds, comment-records, whoami
#       exit 78: not implemented (trust is not supported on disk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/io.sh
source "${SCRIPT_DIR}/../lib/io.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"
# shellcheck source=../lib/transition.sh
source "${SCRIPT_DIR}/../lib/transition.sh"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

_disk_die() { local rc="$1"; shift; printf 'disk.sh: %s\n' "$*" >&2; exit "$rc"; }

usage() {
  cat <<'EOF' >&2
Usage: disk.sh <verb> [args…]   (<dir> is the issues folder, an absolute path)
  fetch <dir> <N>
  state <dir> <N>
  comment-list <dir> <N>
  create <dir> <title> <body-file> [--label X]…
  transition <dir> <N> <on_draft_start|on_ship|on_merge> [--project <name>]
  state-list <dir>
  state-class <dir> <N>
  issue-list <dir>
  state-exists <dir> <status>
  events, comment-records, whoami: not implemented (exit 78)
EOF
  exit 2
}

_disk_is_num() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# _disk_is_abs <path>: 0 for an absolute path. A drive letter (`C:/`, `C:\`)
# is absolute only under Git Bash / MSYS / Cygwin; elsewhere it is relative.
_disk_is_abs() {
  [[ "$1" == /* ]] && return 0
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) [[ "$1" =~ ^[A-Za-z]:[/\\] ]] ;;
    *) return 1 ;;
  esac
}

# _disk_folder <dir> [create]: check the issues folder and cd into it. A
# setter-global — call it bare, never in $(…): it sets PY (python3's absolute
# path, resolved BEFORE the cd so a `.` PATH entry never finds a file in the
# issues folder) and DISK_PY (the module command, as an array). With `create`,
# a missing folder is made (its parent must exist). Exits 1 on any fault.
_disk_folder() {
  local dir
  PY="$(command -v python3 2>/dev/null)" || _disk_die 1 "python3 not found on PATH"
  [[ "$PY" == /* ]] || PY="$PWD/$PY"
  dir="$(expand_tilde "$1")"
  if [ -z "$dir" ] || ! _disk_is_abs "$dir"; then
    _disk_die 1 "issue_source.repo must name the issues folder by an absolute path"
  fi
  if [ "${2:-}" = create ] && [ ! -e "$dir" ]; then
    mkdir -- "$dir" 2>/dev/null || [ -d "$dir" ] \
      || _disk_die 1 "cannot create the issues folder named by issue_source.repo; its parent folder must exist"
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ] || ! cd -- "$dir" 2>/dev/null; then
    _disk_die 1 "the issues folder named by issue_source.repo is missing or unreadable"
  fi
  DISK_PY=("$PY" "${SCRIPT_DIR}/../lib/disk-issue.py")
}

# _disk_mod <verb> <args…>: the format module, with MSYS path conversion off
# (an argument such as a `/`-leading title must reach it unchanged).
_disk_mod() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${DISK_PY[@]}" "$@"; }

# _disk_py <mode> [args…]: the renderer below, reading module JSON on stdin.
_disk_py() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$PY" -I -c "$_DISK_PY" "$@"; }

# _disk_parse <N>: parse <N>.md into DISK_JSON (a setter-global; call it bare).
# A missing file exits 4; a file that fails the check prints its faults and
# exits 5; anything else the module refuses exits 1.
_disk_parse() {
  local n="$1" rc=0
  [ -f "$n.md" ] || _disk_die 4 "no issue $n in the folder named by issue_source.repo"
  if DISK_JSON="$(_disk_mod parse "$n.md")"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 4 ]; then
    printf '%s\n' "$DISK_JSON" | _disk_py faults >&2 || true
    _disk_die 5 "$n.md fails the format check; see docs/disk-issues.md"
  fi
  exit 1
}

# One embedded program renders the module's JSON (stdin, UTF-8) as LF-only
# UTF-8 text, so the output bytes never depend on the platform's locale.
_DISK_PY='
import json, sys

def out(s):
    sys.stdout.buffer.write(s.encode("utf-8"))

def records():
    text = sys.stdin.buffer.read().decode("utf-8")
    return [json.loads(ln) for ln in text.split("\n") if ln.strip()]

def comments(r):
    cs = r.get("comments", [])
    s = "## Comments (%d)\n" % len(cs)
    if cs:
        s += "\n" + "\n\n".join("### @local \u00b7 %s\n\n%s" % (c["date"], c["text"]) for c in cs) + "\n"
    return s

mode = sys.argv[1]
recs = records()
if mode == "faults":
    for r in recs:
        for f in r.get("faults", []):
            out("%d.md:%d: %s\n" % (r["n"], f["line"], f["message"]))
elif mode == "fetch":
    r = recs[0]
    k = r["keys"]
    out("# disk#%d \u2014 %s\n\n" % (r["n"], r["title"]))
    out("- State: %s\n" % k["state"])
    out("- Author: @local\n")
    out("- Labels: %s\n" % ", ".join(k.get("labels", [])))
    out("- URL: disk:%d\n" % r["n"])
    out("\n---\n\n%s\n\n---\n\n" % r["prompt"])
    out(comments(r))
elif mode == "comments":
    out(comments(recs[0]))
elif mode == "state":
    out(recs[0]["keys"]["state"] + "\n")
else:
    sys.exit("disk.sh: unknown render mode " + mode)
'

# _disk_one_args <verb> <args…>: the shared argument rule of the one-issue reads.
_disk_one_args() {
  [ "$#" -eq 3 ] && _disk_is_num "$3" || {
    echo "disk.sh: usage: $1 <dir> <N>" >&2
    exit 2
  }
}

cmd_fetch() {
  _disk_one_args fetch "$@"
  _disk_folder "$1"
  _disk_parse "$2"
  printf '%s\n' "$DISK_JSON" | _disk_py fetch
}

cmd_state() {
  _disk_one_args state "$@"
  _disk_folder "$1"
  _disk_parse "$2"
  printf '%s\n' "$DISK_JSON" | _disk_py state
}

cmd_comment_list() {
  _disk_one_args comment-list "$@"
  _disk_folder "$1"
  _disk_parse "$2"
  printf '%s\n' "$DISK_JSON" | _disk_py comments
}

main() {
  local verb="${1:-}"
  [ "$#" -eq 0 ] || shift
  case "$verb" in
    fetch)        cmd_fetch "$@" ;;
    state)        cmd_state "$@" ;;
    comment-list) cmd_comment_list "$@" ;;
    create|transition|state-list|state-class|issue-list|state-exists)
      _disk_folder "${1:-}"
      bc_die_not_implemented disk "$verb" ;;
    events|comment-records|whoami)
      bc_die_not_implemented disk "$verb" ;;
    *) usage ;;
  esac
}

main "$@"
