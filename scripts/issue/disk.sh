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
  # Under Git Bash the module path is an MSYS path (/c/...), which a native
  # Windows python cannot open once MSYS path conversion is off (_disk_mod),
  # so it gets the same `cygpath -m` treatment as create's body file.
  local mod="${SCRIPT_DIR}/../lib/disk-issue.py"
  if command -v cygpath >/dev/null 2>&1; then mod="$(cygpath -m "$mod")"; fi
  DISK_PY=("$PY" "$mod")
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
  DISK_JSON="$(_disk_mod parse "$n.md")" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 4 ]; then
    printf '%s\n' "$DISK_JSON" | _disk_py faults >&2 || true
    _disk_die 5 "$n.md fails the format check; see docs/disk-issues.md"
  fi
  exit 1
}

# One embedded program renders the module's JSON (stdin, UTF-8) as LF-only
# UTF-8 text, so the output bytes never depend on the platform's locale.
_DISK_PY='
import datetime, json, os, re, subprocess, sys

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

def fail(msg):
    sys.stderr.write("disk.sh: " + msg + "\n")
    sys.exit(1)

def ref(n):
    return "disk:%d" % n

def fault_lines(recs):
    return ["%d.md:%d: %s" % (r["n"], f["line"], f["message"])
            for r in recs for f in r.get("faults", [])]

ISSUE_RE = re.compile(r"^[1-9][0-9]*[.]md$")

def git_walk(paths):
    """Dates from one walk of the git history of the folder (the cwd):
    ({N: date the file was added}, {N: date a commit added `state: closed`}),
    newest commit first. None outside a git work tree, or without git. A
    history git refuses to read (dubious ownership, a broken repo) exits 1:
    never a silent fallback to the modification date. Known limit: a prompt
    line that reads `state: closed` can date a hand close."""
    env = dict(os.environ, LC_ALL="C", GIT_OPTIONAL_LOCKS="0")
    try:
        p = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError:
        return None
    if p.returncode != 0:
        if b"not a git repository" in p.stderr:
            return None
        fail("cannot read the git history of the folder named by issue_source.repo")
    if p.stdout.strip() != b"true":
        return None
    p = subprocess.run(["git", "-c", "core.quotePath=false", "log", "--no-renames",
                        "--date=short", "--format=%x00%cd", "-p", "--unified=0",
                        "--relative", "--"] + paths,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if p.returncode != 0:
        fail("cannot read the git history of the folder named by issue_source.repo")
    added, closed = {}, {}
    date, cur = None, None
    for line in p.stdout.decode("utf-8", "replace").split("\n"):
        line = line.rstrip("\r")
        if line.startswith("\0"):
            date, cur = line[1:], None
        elif line.startswith("diff --git "):
            name = line.rsplit(" b/", 1)[-1]
            cur = int(name[:-3]) if ISSUE_RE.match(name) else None   # a path with / is not an issue
        elif cur is None or date is None:
            continue
        elif line.startswith("new file mode"):
            added.setdefault(cur, date)
        elif line == "+state: closed":
            closed.setdefault(cur, date)
    return added, closed

def mtime(n):
    try:
        return datetime.date.fromtimestamp(os.stat("%d.md" % n).st_mtime).isoformat()
    except OSError:
        return datetime.date.today().isoformat()

def dates(r, walk):
    """(created, closed) of one record: created is the commit that added the
    file, else the modification date; closed (null while open) is the last
    on_merge entry, else the commit that added `state: closed`, else the
    modification date."""
    n = r["n"]
    added, hand = walk if walk else ({}, {})
    created = added.get(n) or mtime(n)
    if r["keys"]["state"] != "closed":
        return created, None
    merged = [c["date"] for c in r["comments"] if c["text"].startswith("on_merge:")]
    return created, (merged[-1] if merged else hand.get(n) or mtime(n))

def klass(r, ip):
    """The one class rule state-list, issue-list and state-class share: closed
    is done; open with the on_draft_start status (case-insensitive, and only
    when one is mapped) is in_progress; any other open issue is open."""
    if r["keys"]["state"] == "closed":
        return "done"
    if ip and r["keys"].get("status", "").casefold() == ip.casefold():
        return "in_progress"
    return "open"

mode = sys.argv[1]
recs = records()
if mode == "faults":
    out("".join(ln + "\n" for ln in fault_lines(recs)))
elif mode == "fetch":
    r = recs[0]
    k = r["keys"]
    out("# disk#%d \u2014 %s\n\n" % (r["n"], r["title"]))
    out("- State: %s\n" % k["state"])
    out("- Author: @local\n")
    out("- Labels: %s\n" % ", ".join(k.get("labels", [])))
    out("- URL: %s\n" % ref(r["n"]))
    out("- Created: %s\n" % dates(r, git_walk(["%d.md" % r["n"]]))[0])
    out("\n---\n\n%s\n\n---\n\n" % r["prompt"])
    out(comments(r))
elif mode == "comments":
    out(comments(recs[0]))
elif mode == "state":
    out(recs[0]["keys"]["state"] + "\n")
elif mode == "list-faults":
    lines = fault_lines(recs)
    k = sum(1 for r in recs if r.get("faults"))
    out("".join(ln + "\n" for ln in lines))
    if lines:
        out("%d issue file(s) in issue_source.repo fail the format check; first: %s\n" % (k, lines[0]))
elif mode == "state-list":
    ip = sys.argv[2].strip(" \t")
    out("".join("%d\t%s\n" % (r["n"], klass(r, ip)) for r in recs))
elif mode == "state-class":
    r = recs[0]
    out("done\tcompleted\n" if klass(r, "") == "done" else "open\t-\n")
elif mode == "issue-list":
    ip = sys.argv[2].strip(" \t")
    walk = git_walk(["."]) if recs else None
    buf = []
    for r in recs:
        k = r["keys"]
        created, closed = dates(r, walk)
        rec = {"id": str(r["n"]), "title": r["title"], "body": r["prompt"],
               "state": k["state"], "class": klass(r, ip),
               "created": created, "closed": closed, "milestone": None,
               "labels": k.get("labels", []), "type": None,
               "parent": ref(k["parent"]) if "parent" in k else None,
               "blocked_by": [], "url": ref(r["n"])}
        buf.append(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    out("".join(buf))
elif mode == "at-target":
    # argv: <target status or ""> <stage>. Exit 0 when the issue is already at
    # the stage target: the mapped status (if any), state closed for on_merge,
    # and a comment entry for the stage. Otherwise print the keys a transition
    # must still set (status, state), one per line, and exit 10.
    r = recs[0]
    t, stage = sys.argv[2], sys.argv[3]
    k = r["keys"]
    need = []
    if t and k.get("status") != t:
        need.append("status")
    if stage == "on_merge" and k["state"] != "closed":
        need.append("state")
    logged = any(c["text"].startswith(stage + ":") for c in r["comments"])
    if not need and logged:
        sys.exit(0)
    out("".join(n + "\n" for n in need))
    sys.exit(10)
else:
    sys.exit("disk.sh: unknown render mode " + mode)
'

# _disk_read_one <verb> <mode> <dir> <N>: the one-issue reads (fetch, state,
# comment-list), which differ only in the render mode.
_disk_read_one() {
  local verb="$1" mode="$2"
  shift 2
  [ "$#" -eq 2 ] && _disk_is_num "$2" || {
    echo "disk.sh: usage: $verb <dir> <N>" >&2
    exit 2
  }
  _disk_folder "$1"
  _disk_parse "$2"
  printf '%s\n' "$DISK_JSON" | _disk_py "$mode"
}

# --- the folder lock (.disk.lock) ------------------------------------------
# One lock per issues folder, shared by create and transition: create's number
# choice and its .last-number reservation, and transition's at-target check and
# its write, each run under it, so two sessions never take one number or append
# two entries for one stage. The lock is the file .disk.lock, created with the
# shell's noclobber (an O_EXCL open, done by bash itself, Git Bash included):
# an external `mkdir` is not a safe lock, because uutils coreutils' mkdir
# (0.10, the default on some current Linux releases) lets two concurrent calls
# both succeed. It is dot-named, so every verb and doctor ignore it, and it is
# always taken OUTSIDE the module's own .disk-issue.lock. A held lock is waited
# on for about ten seconds, then the verb exits 1; a stale lock is never broken
# automatically, because a guessed age can break a live one.
_DISK_LOCKED=0
_disk_unlock() {
  if [ "$_DISK_LOCKED" = 1 ]; then
    rm -f .disk.lock 2>/dev/null || true
    _DISK_LOCKED=0
  fi
}
_disk_lock() {
  local i
  for ((i = 0; i < 100; i++)); do
    if ( set -C; printf '%s\n' "$$" > .disk.lock ) 2>/dev/null; then
      _DISK_LOCKED=1
      trap _disk_unlock EXIT
      return 0
    fi
    sleep 0.1
  done
  _disk_die 1 "the issues folder named by issue_source.repo is locked (.disk.lock); remove it if no devagent command is running"
}

# --- create ----------------------------------------------------------------
# Issue numbers share the module's name rule (^[1-9][0-9]*\.md$) and its
# 18-digit cap. They are compared as strings, by length and then by text, so
# no arithmetic ever runs on an unbounded operand.
_disk_numgt() { (( ${#1} > ${#2} )) || { (( ${#1} == ${#2} )) && [[ "$1" > "$2" ]]; }; }

# _disk_top: the largest issue file number in the folder (the cwd), or 0.
_disk_top() {
  local f n top=0
  for f in [1-9]*.md; do
    [[ "$f" =~ ^[1-9][0-9]*\.md$ ]] && [ -f "$f" ] || continue
    n="${f%.md}"
    if _disk_numgt "$n" "$top"; then top="$n"; fi
  done
  printf '%s' "$top"
}

# _disk_put_last <bytes>: replace .last-number with <bytes> (temp file, then
# rename). A replace that Windows refuses (an indexer holding the file) is
# retried for about a second; returns 1 if it never lands.
_disk_put_last() {
  local i tmp=".last-number.tmp-$$"
  for ((i = 0; i < 10; i++)); do
    if printf '%s' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" .last-number 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# create <dir> <title> <body-file> [--label X]…: write the next issue file and
# print its bare number. N is one more than the larger of the highest <N>.md
# and .last-number, decided under .disk.lock; .last-number is written BEFORE
# the file, so deleting the top file never makes a number come round again.
# The module's create never overwrites: a taken number (its exit 3) moves on
# to the next one, up to 100 times. A failed create puts .last-number back.
cmd_create() {
  if [ "$#" -lt 3 ]; then
    echo "disk.sh: usage: create <dir> <title> <body-file> [--label X]…" >&2
    exit 2
  fi
  local dir="$1" title="$2" bodyf="$3" label labels="" kv=()
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label)
        label="${2:-}"
        if [ "$#" -lt 2 ] || [ -z "${label//[[:space:]]/}" ]; then
          _disk_die 2 "create: --label needs a non-empty value"
        fi
        [[ "$label" != *,* ]] || _disk_die 2 "create: a label cannot contain a comma"
        labels+="${labels:+, }$label"
        shift 2 ;;
      *) _disk_die 2 "create: unknown argument '$1'" ;;
    esac
  done
  [ -z "$labels" ] || kv=("labels=$labels")
  # A relative body file is the caller's, so it is resolved before the cd.
  _disk_is_abs "$bodyf" || bodyf="$PWD/$bodyf"
  [ -f "$bodyf" ] || _disk_die 2 "create: the body file does not exist"
  if command -v cygpath >/dev/null 2>&1; then bodyf="$(cygpath -m "$bodyf")"; fi

  _disk_folder "$dir" create
  _disk_lock
  local last=0 orig="" had=0 top n tries rc err warned=0
  if [ -e .last-number ]; then
    had=1
    orig="$(cat .last-number 2>/dev/null && printf x)" \
      || _disk_die 1 "cannot read .last-number in the folder named by issue_source.repo"
    orig="${orig%x}"
    last="${orig%$'\n'}"
    last="${last%$'\r'}"   # a Git for Windows checkout writes CRLF
    [[ "$last" =~ ^[1-9][0-9]{0,17}$ ]] \
      || _disk_die 1 ".last-number in the folder named by issue_source.repo is not an issue number"
  fi
  top="$(_disk_top)"
  n="$last"
  if _disk_numgt "$top" "$n"; then n="$top"; fi
  for ((tries = 1; tries <= 100; tries++)); do
    # n + 1 has more than 18 digits; checked on every retry, before the add.
    if (( ${#n} > 18 )) || [ "$n" = 999999999999999999 ]; then
      _disk_restore_last "$had" "$orig"
      _disk_die 1 "out of issue numbers: the next number would have more than 18 digits"
    fi
    n=$((10#$n + 1))
    if ! _disk_put_last "$n"$'\n' && [ "$warned" = 0 ]; then
      warned=1
      echo "disk.sh: warning: could not update .last-number in the folder named by issue_source.repo" >&2
    fi
    rc=0
    err="$(_disk_mod create . "$n" "$title" "$bodyf" "${kv[@]}" 2>&1)" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$n"; return 0 ;;
      3) continue ;;
    esac
    _disk_restore_last "$had" "$orig"
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    if [ "$rc" -eq 2 ]; then exit 2; fi
    exit 1
  done
  _disk_restore_last "$had" "$orig"
  _disk_die 1 "no free issue number after 100 tries"
}

# _disk_restore_last <had> <bytes>: put .last-number back as it was.
_disk_restore_last() {
  if [ "$1" = 1 ]; then
    _disk_put_last "$2" || true
  else
    rm -f .last-number 2>/dev/null || true
  fi
}

# --- transition ------------------------------------------------------------
# transition <dir> <N> <stage> [--project <p>]: map the stage to a status
# through [project.<p>.issue_workflow] (or DEVAGENT_DISK_STATUS_<STAGE>) and
# write `status: <mapped>` plus one comment entry in ONE module `set`, so it is
# never left half done. on_merge also writes `state: closed`, even with no
# status mapped. Entry texts (docs/disk-issues.md):
#   <stage>: status <t>              a mapped stage other than on_merge
#   on_merge: status <t>, closed     a mapped on_merge
#   on_merge: closed                 an unmapped on_merge
# An issue already at the target (the status, closed for on_merge, and an
# entry for the stage) is not written. Another unmapped stage warns and
# changes nothing. The check and the write run under .disk.lock, so two
# sessions never append two entries for one stage.
cmd_transition() {
  local t rc=0 need entry
  transition_args disk.sh "$@" || exit 2
  _disk_is_num "$TA_NUM" || _disk_die 2 "transition: <N> must be an issue number"
  case "$TA_STAGE" in
    on_draft_start|on_ship|on_merge) ;;
    quarantine) _disk_die 2 "transition quarantine is not supported on disk" ;;
    *) _disk_die 2 "transition: unknown stage '$TA_STAGE'" ;;
  esac
  _disk_folder "$TA_REPO"
  t="$(stage_map_target disk "$TA_PROJECT" "$TA_STAGE")" || exit 1
  t="${t#"${t%%[!$' \t']*}"}"
  t="${t%"${t##*[!$' \t']}"}"
  [[ "$t" != *[$'\r\n']* ]] || _disk_die 1 "transition: the status mapped for $TA_STAGE contains a line break"
  if [ -z "$t" ] && ! stage_map_closes disk "$TA_STAGE"; then
    transition_unmapped disk "$TA_STAGE" "$TA_PROJECT"
    exit 0
  fi
  _disk_lock
  _disk_parse "$TA_NUM"
  need="$(printf '%s\n' "$DISK_JSON" | _disk_py at-target "$t" "$TA_STAGE")" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -eq 10 ] || exit 1
  local args=()
  [[ $'\n'"$need"$'\n' != *$'\nstatus\n'* ]] || args+=("status=$t")
  [[ $'\n'"$need"$'\n' != *$'\nstate\n'* ]] || args+=("state=closed")
  if [ "$TA_STAGE" = on_merge ]; then
    entry="on_merge: ${t:+status $t, }closed"
  else
    entry="$TA_STAGE: status $t"
  fi
  rc=0
  _disk_mod set "$TA_NUM.md" "${args[@]}" --comment "$entry" || rc=$?
  case "$rc" in
    0) return 0 ;;
    4) exit 5 ;;
    *) exit 1 ;;
  esac
}

# --- the list verbs ---------------------------------------------------------
# _disk_list: every issue of the folder (the cwd), as the module's JSON Lines,
# into DISK_JSON (a setter-global; call it bare). One module `list` call. A
# faulty or unreadable issue file prints one `<N>.md:<line>: <message>` line
# per fault and a last summary line (the line `wbs update` and
# `wbs init --from-tracker` show), then exits 5; an unreadable folder exits 1.
_disk_list() {
  local rc=0
  DISK_JSON="$(_disk_mod list . 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 4 ] || { [ "$rc" -eq 1 ] && [[ "$DISK_JSON" == *'"faults":'* ]]; }; then
    printf '%s\n' "$DISK_JSON" | _disk_py list-faults >&2 || true
    exit 5
  fi
  _disk_die 1 "the issues folder named by issue_source.repo is missing or unreadable"
}

# _disk_ip: the project's on_draft_start status (the per-call DEVAGENT_PROJECT
# that `wbs update` sets), into DISK_IP; an unreadable config exits 1.
_disk_ip() {
  DISK_IP="$(stage_map_target disk "${DEVAGENT_PROJECT:-}" on_draft_start)" || exit 1
}

# state-list <dir>: one `<N>` TAB `<class>` line per issue, sorted by N.
cmd_state_list() {
  [ "$#" -le 1 ] || _disk_die 1 "usage: state-list <dir>"
  _disk_folder "${1:-}"
  _disk_ip
  _disk_list
  printf '%s\n' "$DISK_JSON" | _disk_py state-list "$DISK_IP"
}

# issue-list <dir>: one JSON Lines record per issue, in the contract
# scripts/lib/wbs-import.py check enforces.
cmd_issue_list() {
  [ "$#" -le 1 ] || _disk_die 1 "usage: issue-list <dir>"
  _disk_folder "${1:-}"
  _disk_ip
  _disk_list
  printf '%s\n' "$DISK_JSON" | _disk_py issue-list "$DISK_IP"
}

# state-class <dir> <N>: `<class>` TAB `<reason>` for the merge step: the
# shared rule with no in-progress status (as github's gh_class("")), so an
# open issue is `open`; the reason is never empty.
cmd_state_class() {
  [ "$#" -eq 2 ] && _disk_is_num "$2" || _disk_die 1 "usage: state-class <dir> <N>"
  _disk_folder "$1"
  _disk_parse "$2"
  printf '%s\n' "$DISK_JSON" | _disk_py state-class
}

# state-exists <dir> <status>: a disk status is free text, so any non-empty
# status exists.
cmd_state_exists() {
  [ "$#" -eq 2 ] && [ -n "$2" ] || _disk_die 2 "usage: state-exists <dir> <status>"
  _disk_folder "$1"
}

main() {
  local verb="${1:-}"
  [ "$#" -eq 0 ] || shift
  case "$verb" in
    fetch)        _disk_read_one fetch fetch "$@" ;;
    state)        _disk_read_one state state "$@" ;;
    comment-list) _disk_read_one comment-list comments "$@" ;;
    create)       cmd_create "$@" ;;
    transition)   cmd_transition "$@" ;;
    state-list)   cmd_state_list "$@" ;;
    issue-list)   cmd_issue_list "$@" ;;
    state-class)  cmd_state_class "$@" ;;
    state-exists) cmd_state_exists "$@" ;;
    events|comment-records|whoami)
      bc_die_not_implemented disk "$verb" ;;
    *) usage ;;
  esac
}

main "$@"
