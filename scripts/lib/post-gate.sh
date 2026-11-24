#!/usr/bin/env bash
# scripts/lib/post-gate.sh — the pre-post leak gate (#966).
#
# A library and an executable in one file: sourced, it defines functions, sets
# no shell option and prints nothing; executed, it runs post_gate_main "$@".
#
#   post-gate.sh run   <common> --repo <repo> --backend <name> --backend-script <path>
#                      --record <record> [--draft] [--names-file <records>] [--no-record]
#   post-gate.sh check <permission|tracker|names|review> <common>
#                      [--repo <repo> --backend <name> --backend-script <path>]
#                      [--record <record> [--draft]] [--no-record]
#   post-gate.sh hash [--draft] <file>
#   post-gate.sh record-denylist --project <name> (--issue <issue-dir-name> | --capture <slug>)
#                      [--expect <path>]
#   post-gate.sh denylist-status
#   <common> = --project <name> (--issue <issue-dir-name> | --capture <slug>) --file <text>
#
# Grammar: `--flag value` only (no `=` spelling), each flag at most once, no
# empty value; anything else is usage (exit 2) with no `post-gate:` line.
# `check permission` needs --repo and --backend, `check tracker` also
# --backend-script, `check review` needs --record. --project and --issue or
# --capture are checked on every call by the notifications file's own rules
# (notify_check), so the first recording run cannot be the only one to see a
# malformed work item.
#
# `run` runs the four checks in the order permission, tracker, names, review
# and stops at the first that does not pass. Each check that ran prints one
# line on stderr:
#
#   post-gate: <check> pass
#   post-gate: <check> hold <cause>[ <detail>]
#
# Callers key on <check> and <cause> (POST_GATE_CAUSES); <detail> is for the
# log. No detail holds a denylist entry, text from --file, or a remedy.
#
# Exits: 0 pass · 2 usage · 9 a trust policy that fails to load (refusals.sh)
# · `trust_exit_code leak-held` a hold. `hash` exits 1 when the file cannot be
# read. The spec's §9.1 "Leak gate" section is the contract.
#
# Sourced callers: post_gate_run (the flags of `run`), post_gate_check, one
# post_gate_check_<name> per check, post_gate_hash. Each turns xtrace off
# before any file content enters a variable and never turns it back on. Temp
# files go through pg_tmp onto one cleanup list; the gate never sets a trap —
# the entry point does (`trap pg_cleanup EXIT`).
#
# shellcheck shell=bash

_PG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every library the gate calls, sourced here and never assumed from the caller.
# shellcheck source=scripts/lib/paths.sh
source "$_PG_LIB/paths.sh"
# shellcheck source=scripts/lib/io.sh
source "$_PG_LIB/io.sh"
# shellcheck source=scripts/lib/config.sh
source "$_PG_LIB/config.sh"
# shellcheck source=scripts/lib/refusals.sh
source "$_PG_LIB/refusals.sh"
# shellcheck source=scripts/lib/notify.sh
source "$_PG_LIB/notify.sh"

# The cause tokens, in the order of the checks that raise them: permission,
# tracker, names (six), review (three), then gate-error, which any check raises.
# shellcheck disable=SC2034  # the contract's vocabulary: read by callers and tests
POST_GATE_CAUSES=(
  trust push-mr
  unowned tracker-unavailable
  names-hit denylist-missing-unrecorded denylist-missing denylist-empty denylist-moved no-utf8-locale
  review-missing review-stale review-blocking
  gate-error
)
# The fixed detail of each gate-error class.
# shellcheck disable=SC2034  # read by tests (the spec lists the same tokens)
POST_GATE_ERROR_DETAILS=(
  config-unreadable path-not-absolute path-not-string record-malformed invalid-utf8
  notify-failed record-failed scan-failed scan-disagree owners-malformed
  review-unreadable repo-unkeyable names-file-malformed file-unreadable
  list-missing list-empty
)

# The hold exit, read from the registry by id: no script writes the number.
_PG_HELD="$(trust_exit_code leak-held)" || _PG_HELD=""

_PG_SYNOPSIS='post-gate.sh run <common> --repo <repo> --backend <name> --backend-script <path> --record <record> [--draft] [--names-file <records>] [--no-record]
       post-gate.sh check <permission|tracker|names|review> <common> [--repo <repo> --backend <name> --backend-script <path>] [--record <record> [--draft]] [--no-record]
       post-gate.sh hash [--draft] <file>
       post-gate.sh record-denylist --project <name> (--issue <issue-dir-name> | --capture <slug>) [--expect <path>]
       post-gate.sh denylist-status
       <common> = --project <name> (--issue <issue-dir-name> | --capture <slug>) --file <text>'

# _pg_usage <reason>: the usage diagnostic. Callers return 2. It never starts
# a line with `post-gate:`, which is the checks' own prefix.
_pg_usage() {
  printf 'post-gate.sh: usage: %s\n       %s\n' "$1" "$_PG_SYNOPSIS" >&2
}

# --- temp files ---------------------------------------------------------------

PG_TMP_FILES=()

# pg_tmp [<mktemp-template>]: create a private temp file and put it on the
# cleanup list. SETTER-GLOBAL PG_TMP — call it bare, never in $( … ).
pg_tmp() {
  PG_TMP=""
  if [ "$#" -gt 0 ]; then PG_TMP="$(mktemp "$1")" || return 1; else PG_TMP="$(mktemp)" || return 1; fi
  PG_TMP_FILES+=("$PG_TMP")
}

# pg_cleanup: remove every file pg_tmp made. The entry point's EXIT trap.
pg_cleanup() {
  local f
  for f in "${PG_TMP_FILES[@]}"; do
    [ -z "$f" ] || rm -f -- "$f"
  done
  PG_TMP_FILES=()
}

# --- lines --------------------------------------------------------------------

_pg_pass() { printf 'post-gate: %s pass\n' "$1" >&2; }

# _pg_hold <check> <cause> [<detail>]: print the hold line; returns the hold
# exit, so `_pg_hold …; return` ends a check.
_pg_hold() {
  printf 'post-gate: %s hold %s%s\n' "$1" "$2" "${3:+ $3}" >&2
  return "${_PG_HELD:-1}"
}

# --- grammar ------------------------------------------------------------------

declare -gA PG_ARG=()

# _pg_parse <run|check|record> <args…>: fill PG_ARG[<flag>] from `--flag value`
# pairs and switches. 2 (after the usage line) on an unknown flag, the `=`
# spelling, a stray word, a repeat, a missing or an empty value.
_pg_parse() {
  local mode="$1" a kind
  shift
  PG_ARG=()
  while [ "$#" -gt 0 ]; do
    a="$1" kind=""
    case "$a" in
      --project | --issue | --capture) kind=value ;;
      --file | --repo | --backend | --backend-script | --record) [ "$mode" = record ] || kind=value ;;
      --names-file) [ "$mode" != run ] || kind=value ;;
      --expect) [ "$mode" != record ] || kind=value ;;
      --draft | --no-record) [ "$mode" = record ] || kind=switch ;;
    esac
    if [ -z "$kind" ]; then
      _pg_usage "unexpected argument '$a'"
      return 2
    fi
    a="${a#--}"
    if [ -n "${PG_ARG[$a]+x}" ]; then
      _pg_usage "--$a is given twice"
      return 2
    fi
    if [ "$kind" = switch ]; then
      PG_ARG[$a]=1
      shift
      continue
    fi
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
      _pg_usage "--$a needs a value"
      return 2
    fi
    PG_ARG[$a]="$2"
    shift 2
  done
}

# _pg_require <flag>…: 2 (after the usage line) when a flag is absent.
_pg_require() {
  local f
  for f in "$@"; do
    if [ -z "${PG_ARG[$f]+x}" ]; then
      _pg_usage "--$f is required"
      return 2
    fi
  done
}

# _pg_item: --project plus exactly one of --issue and --capture, checked by
# notify_check — the notifications file's own rules, so the gate and the audit
# line it may write cannot disagree on what a work item is. SETTER-GLOBALS:
# PG_ITEM[] (the notify fields) and PG_FAULT (a gate-error detail every check
# of this call holds with, when the rules could not be read). 2 on usage.
_pg_item() {
  local rc=0 err
  PG_ITEM=() PG_FAULT=""
  _pg_require project || return 2
  if [ -n "${PG_ARG[issue]+x}" ] && [ -n "${PG_ARG[capture]+x}" ]; then
    _pg_usage "give one of --issue and --capture, not both"
    return 2
  fi
  if [ -n "${PG_ARG[issue]+x}" ]; then
    PG_ITEM=(event=notify "project=${PG_ARG[project]}" "issue=${PG_ARG[issue]}" "detail=denylist path recorded")
  elif [ -n "${PG_ARG[capture]+x}" ]; then
    PG_ITEM=(event=notify "project=${PG_ARG[project]}" "capture=${PG_ARG[capture]}" "detail=denylist path recorded")
  else
    _pg_usage "one of --issue and --capture is required"
    return 2
  fi
  err="$(notify_check "${PG_ITEM[@]}" 2>&1 >/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    2)
      # a refusal names its rule and never repeats a field value.
      err="${err%%$'\n'*}"
      _pg_usage "--project, --issue or --capture is not valid (${err#notify: })"
      return 2
      ;;
    *) PG_FAULT=config-unreadable ;;
  esac
}

# --- hash ---------------------------------------------------------------------

# _pg_draft_bytes <file>: the file's bytes on stdout, with the match of
# ` \(https?://[^ ()]+\)$` removed from the first line outside a code fence
# that starts `Parent epic: ` (crrf appends that URL after the review). The
# fence rule is wbs-parser.py's own classifier, the one wbs-import.py reads
# parent lines with. A trailing CR counts as part of the line's end; every
# other byte, the final newline or its absence included, passes unchanged.
_pg_draft_bytes() {
  python3 -I -X utf8 - "$_PG_LIB/wbs-parser.py" "$1" <<'PY'
import importlib.util
import re
import sys

parser_path, path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wbs_parser", parser_path)
parser = importlib.util.module_from_spec(spec)
sys.modules["wbs_parser"] = parser
spec.loader.exec_module(parser)

with open(path, "rb") as fh:
    lines = fh.read().split(b"\n")
kinds = parser._classify_lines([ln.decode("utf-8", "surrogateescape") + "\n" for ln in lines])[0]
url = re.compile(rb" \(https?://[^ ()]+\)(?=\r?\Z)")
for i, (kind, _match) in enumerate(kinds):
    if kind in ("fence", "code"):
        continue
    if lines[i].startswith(b"Parent epic: "):
        lines[i] = url.sub(b"", lines[i], count=1)
        break
sys.stdout.buffer.write(b"\n".join(lines))
sys.stdout.buffer.flush()
PY
}

# _pg_hash [--draft] <file>: the digest the review check compares — sha256sum
# of the bytes read on stdin, lower-case hex. 1 when the file cannot be read
# or hashed; stdout stays empty then.
_pg_hash() {
  local draft=0 file out
  if [ "${1:-}" = --draft ]; then
    draft=1
    shift
  fi
  file="${1:-}"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then return 1; fi
  if [ "$draft" = 1 ]; then
    out="$(set -o pipefail; _pg_draft_bytes "$file" | sha256sum)" || return 1
  else
    out="$(sha256sum < "$file")" || return 1
  fi
  out="${out%% *}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}

_pg_hash_main() {
  local args=()
  case "$#" in
    1) args=("$1") ;;
    2)
      if [ "$1" != --draft ]; then
        _pg_usage "hash takes [--draft] <file>"
        return 2
      fi
      args=(--draft "$2")
      ;;
    *)
      _pg_usage "hash takes [--draft] <file>"
      return 2
      ;;
  esac
  if [ -z "${args[-1]}" ] || [[ "${args[-1]}" == --* ]]; then
    _pg_usage "hash takes [--draft] <file>"
    return 2
  fi
  if ! _pg_hash "${args[@]}"; then
    printf 'post-gate.sh: hash: cannot read %s\n' "${args[-1]}" >&2
    return 1
  fi
}

# post_gate_hash [--draft] <file>
post_gate_hash() {
  { set +x; } 2>/dev/null
  local rc=0
  _pg_hash_main "$@" || rc=$?
  return "$rc"
}

# --- the review check ---------------------------------------------------------

# _pg_review_read <record>: the strict parse. Lines are read byte-wise, with
# one trailing CR removed and a last line with no newline still read.
# SETTER-GLOBALS PG_REVIEW_SHA and PG_REVIEW_N; 1 unless exactly one line starts
# `Reviewed-sha256:` and is 64 lower-case hex digits, and exactly one starts
# `### Blocking (` and is a plain count.
_pg_review_read() {
  local LC_ALL=C line shas=0 heads=0 ok=1
  PG_REVIEW_SHA="" PG_REVIEW_N=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      'Reviewed-sha256:'*)
        shas=$((shas + 1))
        if [[ "$line" =~ ^Reviewed-sha256:\ ([0-9a-f]{64})$ ]]; then PG_REVIEW_SHA="${BASH_REMATCH[1]}"; else ok=0; fi
        ;;
      '### Blocking ('*)
        heads=$((heads + 1))
        if [[ "$line" =~ ^'### Blocking ('(0|[1-9][0-9]{0,8})')'$ ]]; then PG_REVIEW_N="${BASH_REMATCH[1]}"; else ok=0; fi
        ;;
    esac
  done < "$1"
  [ "$ok" = 1 ] && [ "$shas" -eq 1 ] && [ "$heads" -eq 1 ]
}

# _pg_review: the record, not the review's claims.
_pg_review() {
  local rec="${PG_ARG[record]}" digest draft=()
  if [ ! -e "$rec" ] && [ ! -L "$rec" ]; then
    _pg_hold review review-missing
    return
  fi
  if [ ! -f "$rec" ] || [ ! -r "$rec" ]; then
    _pg_hold review gate-error review-unreadable
    return
  fi
  if ! _pg_review_read "$rec"; then
    _pg_hold review review-missing
    return
  fi
  [ -z "${PG_ARG[draft]+x}" ] || draft=(--draft)
  if ! digest="$(_pg_hash "${draft[@]}" "${PG_ARG[file]}")"; then
    _pg_hold review gate-error file-unreadable
    return
  fi
  if [ "$digest" != "$PG_REVIEW_SHA" ]; then
    _pg_hold review review-stale
    return
  fi
  if [ "$PG_REVIEW_N" != 0 ]; then
    _pg_hold review review-blocking
    return
  fi
  _pg_pass review
}

# --- the checks' doors ---------------------------------------------------------

# _pg_one <check>: run one check on the parsed call. 0 pass, the hold exit on a
# hold. A fault found while reading the call (PG_FAULT) holds here, as the
# first check's gate-error.
_pg_one() {
  if [ -n "${PG_FAULT:-}" ]; then
    _pg_hold "$1" gate-error "$PG_FAULT"
    return
  fi
  case "$1" in
    review) _pg_review ;;
    # Tasks 5-7 build these; until then they fail closed.
    *) _pg_hold "$1" gate-error not-built ;;
  esac
}

_pg_check_main() {
  local check="${1:-}"
  case "$check" in
    permission | tracker | names | review) shift ;;
    *)
      _pg_usage "check takes one of permission, tracker, names, review"
      return 2
      ;;
  esac
  _pg_parse check "$@" || return 2
  _pg_require file || return 2
  case "$check" in
    permission) _pg_require repo backend || return 2 ;;
    tracker) _pg_require repo backend backend-script || return 2 ;;
    review) _pg_require record || return 2 ;;
  esac
  if [ -n "${PG_ARG[draft]+x}" ] && [ -z "${PG_ARG[record]+x}" ]; then
    _pg_usage "--draft needs --record"
    return 2
  fi
  _pg_item || return 2
  _pg_one "$check"
}

_pg_run_main() {
  local check
  _pg_parse run "$@" || return 2
  _pg_require file repo backend backend-script record || return 2
  _pg_item || return 2
  for check in permission tracker names review; do
    _pg_one "$check" || return
  done
}

# Task 5 builds both; until then the grammar is live and the bodies fail closed.
_pg_record_main() {
  _pg_parse record "$@" || return 2
  _pg_item || return 2
  _pg_hold names gate-error not-built
}

_pg_status_main() {
  if [ "$#" -ne 0 ]; then
    _pg_usage "denylist-status takes no argument"
    return 2
  fi
  return 1
}

# post_gate_record_denylist <flags of `record-denylist`>
post_gate_record_denylist() {
  { set +x; } 2>/dev/null
  local rc=0
  _pg_record_main "$@" || rc=$?
  return "$rc"
}

# post_gate_denylist_status
post_gate_denylist_status() {
  { set +x; } 2>/dev/null
  local rc=0
  _pg_status_main "$@" || rc=$?
  return "$rc"
}

# post_gate_check <permission|tracker|names|review> <flags of `check`>
post_gate_check() {
  { set +x; } 2>/dev/null
  local rc=0
  _pg_check_main "$@" || rc=$?
  return "$rc"
}

post_gate_check_permission() { post_gate_check permission "$@"; }
post_gate_check_tracker() { post_gate_check tracker "$@"; }
post_gate_check_names() { post_gate_check names "$@"; }
post_gate_check_review() { post_gate_check review "$@"; }

# post_gate_run <flags of `run`>: the full gate. 0 when all four checks passed.
post_gate_run() {
  { set +x; } 2>/dev/null
  local rc=0
  _pg_run_main "$@" || rc=$?
  return "$rc"
}

# post_gate_main <args…>: the executed grammar.
post_gate_main() {
  local sub="${1:-}"
  if [ "$#" -eq 0 ]; then
    _pg_usage "a subcommand is required"
    return 2
  fi
  shift
  case "$sub" in
    run) post_gate_run "$@" ;;
    check) post_gate_check "$@" ;;
    hash) post_gate_hash "$@" ;;
    record-denylist) post_gate_record_denylist "$@" ;;
    denylist-status) post_gate_denylist_status "$@" ;;
    *)
      _pg_usage "unknown subcommand '$sub'"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap pg_cleanup EXIT
  _pg_rc=0
  post_gate_main "$@" || _pg_rc=$?
  exit "$_pg_rc"
fi
