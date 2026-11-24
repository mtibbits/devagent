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
# Sourced callers: post_gate_run (the flags of `run`), post_gate_check,
# post_gate_hash. Each turns xtrace off before any file content enters a
# variable and never turns it back on. Temp files go through pg_tmp onto one
# cleanup list; the gate never sets a trap — the entry point does
# (`trap pg_cleanup EXIT`).
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
# shellcheck source=scripts/lib/trust.sh
source "$_PG_LIB/trust.sh"
# shellcheck source=scripts/lib/permission.sh
source "$_PG_LIB/permission.sh"
# shellcheck source=scripts/lib/notify.sh
source "$_PG_LIB/notify.sh"
# shellcheck source=scripts/lib/utf8-locale.sh
source "$_PG_LIB/utf8-locale.sh"
# The list parsers and the private-name predicate (potholes.sh) load with the
# template resolver.
# shellcheck source=scripts/lib/template_resolve.sh
source "$_PG_LIB/template_resolve.sh"

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

# The UTF-8 locale candidates the names scan pins, never the ambient locale.
_PG_LOCALES=(C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8)

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
  # The hold exit, read from the registry by id: no script writes the number.
  # A failed lookup falls back to 2, a "not posted" exit, never 1 (unknown).
  [ -n "${_PG_HELD:-}" ] || _PG_HELD="$(trust_exit_code leak-held)" || _PG_HELD=2
  return "$_PG_HELD"
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
  local rc=0 err key
  PG_ITEM=() PG_FAULT=""
  _pg_require project || return 2
  if [ -n "${PG_ARG[issue]+x}" ] && [ -n "${PG_ARG[capture]+x}" ]; then
    _pg_usage "give one of --issue and --capture, not both"
    return 2
  fi
  if [ -n "${PG_ARG[issue]+x}" ]; then
    key=issue
  elif [ -n "${PG_ARG[capture]+x}" ]; then
    key=capture
  else
    _pg_usage "one of --issue and --capture is required"
    return 2
  fi
  PG_ITEM=(event=notify "project=${PG_ARG[project]}" "$key=${PG_ARG[$key]}" "detail=denylist path recorded")
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
  local file="${!#}"
  if ! { [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$1" = --draft ]; }; } \
    || [ -z "$file" ] || [[ "$file" == --* ]]; then
    _pg_usage "hash takes [--draft] <file>"
    return 2
  fi
  if ! _pg_hash "$@"; then
    printf 'post-gate.sh: hash: cannot read %s\n' "$file" >&2
    return 1
  fi
}

# _pg_entry <main> <args…>: every public function's body. xtrace goes off
# before any file content enters a variable and stays off; the || keeps a
# caller's errexit from ending the gate before it returns its code.
_pg_entry() {
  { set +x; } 2>/dev/null
  local rc=0
  "$@" || rc=$?
  return "$rc"
}

# post_gate_hash [--draft] <file>
post_gate_hash() { _pg_entry _pg_hash_main "$@"; }

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

# --- the permission check -----------------------------------------------------
#
# With a trust policy on the host (#713) the check holds `trust` when the named
# project is in scope, or when any key the target repo can reach is one of the
# policy's scopes: #953's screened hash covers the issue body and every trusted
# comment, so a post there would trip #718's drift. A policy that fails to
# load refuses as every entry point does (exit 9).
#
# With no policy, or with project and target both out of scope, the named
# project's permissions.push_mr decides, read through permission_value and
# never from the environment. Any OTHER configured project whose issue_source
# or issue_source_fork reaches a key the target reaches must have push_mr true
# as well (keys as _trust_candidate_keys builds them, never raw strings), so
# one project's permission cannot open another's tracker.

# _pg_keys_meet <keys-a> <keys-b>: 0 iff the two key lists (one per line) share a key.
_pg_keys_meet() {
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if _pg_owner_listed "$2" "$a"; then return 0; fi
  done <<<"$1"
  return 1
}

_pg_permission() {
  local project="${PG_ARG[project]}" repo="${PG_ARG[repo]}" backend="${PG_ARG[backend],,}"
  local cands key other section ob orepo okeys projects frc
  # The caller's trust state is not this check's to change. permission_value
  # reads TRUST_IN_SCOPE and TRUST_VAL, so both are scoped to the check, as is
  # everything the trust setters fill. (trust_load unsets and re-declares
  # TRUST_ID and TRUST_VAL globally: under a policy those two end up holding
  # the host's policy, which is what any caller's own load put there.)
  local TRUST_IN_SCOPE=0
  local -A TRUST_VAL=()
  local TRUST_HOST=0 TRUST_DIR="" TRUST_SOURCE="" TRUST_USER_IGNORED="" TRUST_DEFECT=""
  local TRUST_LOAD_ERR="" TRUST_DIGEST="" TRUST_FILE=""
  local -a TRUST_EMPTY_DIRS=() TRUST_SCOPES=() TRUST_SCOPE_KEYS=() TRUST_SCOPE_BACKENDS=() TRUST_SCOPE_REPOS=()

  # Setter-globals and refusals: called bare, never in $( … ).
  trust_locate_host || refuse policy-defect "$TRUST_DIR" "$TRUST_DEFECT"
  if [ "$TRUST_HOST" = 1 ]; then
    trust_load
    if trust_project_scope "$project"; then
      _pg_hold permission trust
      return
    fi
  fi
  if ! cands="$(_trust_candidate_keys "$backend" "$repo" 2>/dev/null)" || [ -z "$cands" ]; then
    _pg_hold permission gate-error repo-unkeyable
    return
  fi
  if [ "$TRUST_HOST" = 1 ]; then
    while IFS= read -r key; do
      if [ -n "$key" ] && _trust_in_scopes "$key"; then
        _pg_hold permission trust
        return
      fi
    done <<<"$cands"
  fi

  # Out of scope, or no policy: the project's own gate, from its config.
  if [ "$(permission_value "$project" push_mr)" != true ]; then
    _pg_hold permission push-mr "project=$project"
    return
  fi
  if ! projects="$(set -o pipefail; config_list_projects 2>/dev/null)"; then
    _pg_hold permission gate-error config-unreadable
    return
  fi
  while IFS= read -r other; do
    if [ -z "$other" ] || [ "$other" = "$project" ]; then continue; fi
    for section in issue_source issue_source_fork; do
      # The backend first: a built-in backend other than the target's cannot
      # name the target's tracker, and skipping it saves two config reads.
      # rc 1 is an absent field; anything above is a config that cannot be read.
      frc=0; ob="$(config_get_project_field "$other" "$section.backend" 2>/dev/null)" || frc=$?
      if [ "$frc" -ge 2 ]; then _pg_hold permission gate-error config-unreadable; return; fi
      ob="${ob//$'\r'/}"
      ob="${ob,,}"
      [ -n "$ob" ] || continue
      if stage_map_builtin "$ob" && [ "$ob" != "$backend" ]; then continue; fi
      frc=0; orepo="$(config_get_project_field "$other" "$section.repo" 2>/dev/null)" || frc=$?
      if [ "$frc" -ge 2 ]; then _pg_hold permission gate-error config-unreadable; return; fi
      orepo="${orepo//$'\r'/}"
      [ -n "$orepo" ] || continue
      # a source that cannot be keyed as the target's backend names no tracker of it.
      okeys="$(_trust_candidate_keys "$backend" "$orepo" 2>/dev/null)" || continue
      if _pg_keys_meet "$cands" "$okeys"; then
        if [ "$(permission_value "$other" push_mr)" != true ]; then
          _pg_hold permission push-mr "project=$other"
          return
        fi
        break
      fi
    done
  done <<<"$projects"
  _pg_pass permission
}

# --- the tracker check --------------------------------------------------------
#
# auto_post_owners (top level of the user config only) is read and every entry
# checked first, for every backend. Then:
#   github  the owner is the second path part of the repo's canonical key. An
#           entry github:<owner> (case-insensitive, on any host: the grammar
#           has no host part) passes with no call. Otherwise the repo owner's
#           numeric id (`repo-owner`) must equal the authenticated account's
#           (`whoami`), both asked through the backend script the caller will
#           write through, so both answer for the host the write goes to. This
#           is the one caller of whoami with trust off (spec §9.1;
#           tests/events-trust-off.bats allow-lists this file).
#   gitlab  the namespace (the key's path minus the project) must be listed,
#           compared lower-cased; a parent group does not cover a subgroup.
#   jira    <repo>, the project key, must be listed exactly.
#   other   unowned.
# GitLab and JIRA have no whoami (#900), so neither makes a backend call.

_PG_OWNER_RE='^(github:[A-Za-z0-9][A-Za-z0-9_-]*|gitlab:[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*|jira:[A-Z][A-Z0-9_]*)$'

# _pg_owner_listed <owners> <entry> [fold]: 0 iff <entry> is a line of <owners>
# (both sides lower-cased with `fold`).
_pg_owner_listed() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -z "${3:-}" ] || line="${line,,}"
    if [ "$line" = "$2" ]; then return 0; fi
  done <<<"$1"
  return 1
}

_pg_tracker() {
  local repo="${PG_ARG[repo]}" backend="${PG_ARG[backend],,}"
  local backend_script="${PG_ARG["backend-script"]}"
  local owners="" rc=0 entry key rest owner out oid who
  owners="$(config_get_global_list auto_post_owners 2>/dev/null)" || rc=$?
  case "$rc" in
    0 | 1) ;;   # absent is an empty list
    3) _pg_hold tracker gate-error owners-malformed; return ;;
    *) _pg_hold tracker gate-error config-unreadable; return ;;
  esac
  if [ -n "$owners" ]; then
    while IFS= read -r entry; do
      if ! [[ "$entry" =~ $_PG_OWNER_RE ]]; then
        _pg_hold tracker gate-error owners-malformed
        return
      fi
    done <<<"$owners"
  fi
  case "$backend" in
    github)
      if ! key="$(_trust_py key github "$repo" 2>/dev/null)"; then
        _pg_hold tracker gate-error repo-unkeyable
        return
      fi
      rest="${key#github:}"   # <host>/<owner>/<name>
      rest="${rest#*/}"
      owner="${rest%%/*}"
      if [ -z "$owner" ]; then
        _pg_hold tracker gate-error repo-unkeyable
        return
      fi
      if _pg_owner_listed "$owners" "github:$owner" fold; then
        _pg_pass tracker
        return
      fi
      rc=0
      out="$("$backend_script" repo-owner "$repo")" || rc=$?
      oid="${out%%$'\t'*}"
      if [ "$rc" -ne 0 ] || ! [[ "$oid" =~ ^[1-9][0-9]*$ ]]; then
        _pg_hold tracker tracker-unavailable
        return
      fi
      rc=0
      who="$("$backend_script" whoami "$repo")" || rc=$?
      who="${who//$'\r'/}"
      if [ "$rc" -ne 0 ] || ! [[ "$who" =~ ^[1-9][0-9]*$ ]]; then
        _pg_hold tracker tracker-unavailable
        return
      fi
      if [ "$oid" != "$who" ]; then
        _pg_hold tracker unowned
        return
      fi
      _pg_pass tracker
      ;;
    gitlab)
      if ! key="$(_trust_py key gitlab "$repo" 2>/dev/null)"; then
        _pg_hold tracker gate-error repo-unkeyable
        return
      fi
      rest="${key#gitlab:}"   # <host>/<namespace>/<project>
      rest="${rest#*/}"
      owner="${rest%/*}"
      if [ -z "$owner" ] || [ "$owner" = "$rest" ]; then
        _pg_hold tracker gate-error repo-unkeyable
        return
      fi
      if ! _pg_owner_listed "$owners" "gitlab:$owner" fold; then
        _pg_hold tracker unowned
        return
      fi
      _pg_pass tracker
      ;;
    jira)
      if ! _pg_owner_listed "$owners" "jira:$repo"; then
        _pg_hold tracker unowned
        return
      fi
      _pg_pass tracker
      ;;
    *)
      _pg_hold tracker unowned
      ;;
  esac
}

# --- the names check ----------------------------------------------------------
#
# First match wins:
#   1. config unreadable; denylist_path not a string, or not absolute after ~
#      expansion; a record file that is not one line        → gate-error
#   2. a recorded path that the configured one no longer names → denylist-moved
#   3. the list missing or unreadable → denylist-missing (recorded) or
#      denylist-missing-unrecorded
#   4. zero entries                                          → denylist-empty
#   5. no UTF-8 locale among the fixed candidates            → no-utf8-locale
#   6. the list or the scanned text not valid UTF-8          → gate-error
#   7. not recorded: record the path (unless --no-record), audit line first
#   8. the scan; a roster left empty by the subtraction → denylist-empty roster-empty
#
# Moved comes before missing, so a config repointed to a file that is not there
# reads as the move it is. The record is replaced by a temp file and `mv`; on
# Windows a `mv` onto a file another process holds open fails, which is a
# transient gate-error (record-failed): the check holds and the next run
# records. Two racing first runs give two audit lines and one record.

# _pg_record_file: the recorded-path file.
_pg_record_file() { printf '%s/state/post-gate-denylist-path\n' "$(devagent_home)"; }

# _pg_is_absolute <path>: `/…`; where cygpath exists paths were already
# converted to that form.
_pg_is_absolute() { [[ "$1" == /* ]]; }

# _pg_posix_path <path>: on Git Bash (cygpath exists) the POSIX spelling of a
# `C:/…` or `C:\…` path, so one file has one spelling; elsewhere unchanged.
# SETTER-GLOBAL PG_POSIX.
_pg_posix_path() {
  PG_POSIX="$1"
  if [[ "$1" =~ ^[A-Za-z]:[\\/] ]] && command -v cygpath >/dev/null 2>&1; then
    PG_POSIX="$(cygpath -u -- "$1" 2>/dev/null)" || PG_POSIX="$1"
  fi
}

# _pg_resolve <path>: SETTER-GLOBAL PG_RESOLVED, "<physical directory>/<name>".
# 1 with PG_RESOLVED empty when the directory cannot be entered: the two
# halves are never joined on a failure, so a missing directory cannot resolve
# to "/<name>".
_pg_resolve() {
  local dir base phys
  PG_RESOLVED=""
  dir="$(dirname -- "$1")" || return 1
  base="$(basename -- "$1")" || return 1
  phys="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
  if [ -z "$phys" ] || [ -z "$base" ]; then return 1; fi
  PG_RESOLVED="${phys%/}/$base"
}

# _pg_same_file <a> <b>: 0 iff both name one file — by identity (-ef) when both
# exist, else by resolved spelling; a path whose directory is missing equals
# nothing.
_pg_same_file() {
  local ra
  if [ -e "$1" ] && [ -e "$2" ]; then
    [ "$1" -ef "$2" ]
    return
  fi
  _pg_resolve "$1" || return 1
  ra="$PG_RESOLVED"
  _pg_resolve "$2" || return 1
  [ "$ra" = "$PG_RESOLVED" ]
}

# _pg_denylist_path: row 1's config half. SETTER-GLOBALS PG_DL_PATH (the
# configured path, ~ expanded; the default only when the key is truly absent),
# PG_DL_RESOLVED ("" when its directory is missing) and, on 1, PG_DL_DETAIL.
# `get` answers 1 for a table as for an absent key and prints any other value's
# literal, so `get-list` tells the cases apart (as issue-source.sh does): a
# table or an array is path-not-string, never a fall back to the default.
_pg_denylist_path() {
  local rc=0 lrc=0 p
  PG_DL_PATH="" PG_DL_RESOLVED="" PG_DL_DETAIL=""
  p="$(config_get_global_path denylist_path 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    1)
      _config_toml get-list "$(config_path)" paths.denylist_path >/dev/null 2>&1 || lrc=$?
      case "$lrc" in
        1) p="${HOME:-}/.config/denylist.txt" ;;   # truly absent: the default, ~/.config/denylist.txt
        0 | 3) PG_DL_DETAIL="path-not-string"; return 1 ;;
        *) PG_DL_DETAIL="config-unreadable"; return 1 ;;
      esac
      ;;
    *) PG_DL_DETAIL="config-unreadable"; return 1 ;;
  esac
  _pg_posix_path "$p"
  p="$PG_POSIX"
  if ! _pg_is_absolute "$p"; then
    PG_DL_DETAIL="path-not-absolute"
    _config_toml get-list "$(config_path)" paths.denylist_path >/dev/null 2>&1 || lrc=$?
    [ "$lrc" -ne 0 ] || PG_DL_DETAIL="path-not-string"
    return 1
  fi
  PG_DL_PATH="$p"
  _pg_resolve "$p" || true
  PG_DL_RESOLVED="$PG_RESOLVED"
}

# _pg_recorded_read: SETTER-GLOBAL PG_DL_RECORDED, the recorded path, or ""
# when no record exists. 1 when the record is not one line holding an absolute
# path (read byte-wise; a last line with no newline is still read).
_pg_recorded_read() {
  local LC_ALL=C f line n=0 first=""
  PG_DL_RECORDED=""
  f="$(_pg_record_file)"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 0; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -gt 1 ] || first="$line"
  done < "$f"
  if [ "$n" -ne 1 ] || ! _pg_is_absolute "$first"; then return 1; fi
  PG_DL_RECORDED="$first"
}

# _pg_denylist_locate: rows 1 to 3. SETTER-GLOBAL PG_DL_STATE: ok | moved |
# missing | missing-unrecorded | error (PG_DL_DETAIL names the gate-error).
_pg_denylist_locate() {
  local cur
  PG_DL_STATE=error
  _pg_denylist_path || return 0
  if ! _pg_recorded_read; then
    PG_DL_DETAIL="record-malformed"
    return 0
  fi
  if [ -n "$PG_DL_RECORDED" ]; then
    if [ -e "$PG_DL_RECORDED" ] && [ -e "$PG_DL_PATH" ]; then
      if ! [ "$PG_DL_RECORDED" -ef "$PG_DL_PATH" ]; then PG_DL_STATE=moved; return 0; fi
    else
      # a path whose directory is missing has no resolved spelling: compare as written.
      cur="${PG_DL_RESOLVED:-$PG_DL_PATH}"
      if [ "$cur" != "$PG_DL_RECORDED" ]; then PG_DL_STATE=moved; return 0; fi
    fi
  fi
  if [ ! -f "$PG_DL_PATH" ] || [ ! -r "$PG_DL_PATH" ]; then
    PG_DL_STATE="missing-unrecorded"
    [ -z "$PG_DL_RECORDED" ] || PG_DL_STATE=missing
    return 0
  fi
  PG_DL_STATE=ok
}

# _pg_entries: row 4's input. SETTER-GLOBAL PG_ENTRIES, the list's entries one
# per line (the shared parser, byte-wise). 1 when the list cannot be read.
_pg_entries() {
  local rc=0
  PG_ENTRIES="$(LC_ALL=C potholes_fixture_private_names "$PG_DL_PATH" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ]
}

# _pg_roster <locale>: SETTER-GLOBAL PG_ROSTER = the entries minus the
# configured project names minus every name on a `# public:` line (split on
# whitespace, as doctor and the canary read it), compared as whole lines,
# literally and case-insensitively under <locale>. Empty when nothing is left:
# grep is never given an empty pattern, which would match every line. 1 when
# the config or the list cannot be read, or grep cannot run.
_pg_roster() {
  local loc="$1" projects pub line w sub="" rc=0
  local -a words=()
  PG_ROSTER=""
  projects="$(set -o pipefail; config_list_projects 2>/dev/null)" || return 1
  pub="$(LC_ALL=C potholes_fixture_public "$PG_DL_PATH" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [ -z "$line" ] || sub+="$line"$'\n'
  done <<<"$projects"
  while IFS= read -r line; do
    read -ra words <<<"$line"
    for w in "${words[@]}"; do sub+="$w"$'\n'; done
  done <<<"$pub"
  if [ -z "$sub" ]; then
    PG_ROSTER="$PG_ENTRIES"
    return 0
  fi
  PG_ROSTER="$(LC_ALL="$loc" grep -vixF -f <(printf '%s' "$sub") <<<"$PG_ENTRIES")" || rc=$?
  [ "$rc" -le 1 ]
}

# _pg_utf8_valid <locale> <file>: 0 valid UTF-8, 1 not, 2 could not tell. A
# line that `.*` does not match in full under a UTF-8 locale holds an invalid
# sequence.
_pg_utf8_valid() {
  local rc=0
  LC_ALL="$1" grep -axvc '.*' -- "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

# _pg_record_write: row 7 — the audit line, then the record. notify_check
# first, then notify_append (event notify, the call's project and issue or
# capture, no step, no question, detail "denylist path recorded"), then the
# resolved path through a temp file (pg_tmp, so pg_cleanup removes it) and mv.
# 1 with PG_RECORD_FAULT naming the gate-error detail; nothing is recorded
# then.
_pg_record_write() {
  local f
  # a record that could never be written gets no audit line.
  PG_RECORD_FAULT="record-failed"
  f="$(_pg_record_file)"
  if [ -z "$PG_DL_RESOLVED" ] || [ -d "$f" ]; then return 1; fi
  PG_RECORD_FAULT="notify-failed"
  notify_check "${PG_ITEM[@]}" || return 1
  notify_append "${PG_ITEM[@]}" || return 1
  PG_RECORD_FAULT="record-failed"
  pg_tmp "$f.XXXXXX" || return 1
  if ! printf '%s\n' "$PG_DL_RESOLVED" > "$PG_TMP" || ! mv -f -- "$PG_TMP" "$f"; then
    return 1
  fi
  PG_RECORD_FAULT=""
}

# _pg_line_numbers <locale> <grep-flags> <text>: the numbers of the lines of
# <text> that match a pattern read from stdin, one per line. The matched text
# is cut away inside the pipe and never enters a variable. rc is grep's.
_pg_line_numbers() {
  ( set -o pipefail; LC_ALL="$1" grep "$2" -f - -- "$3" | LC_ALL=C cut -d: -f1 )
}

# _pg_names_file_split <records> <out>: --names-file, one `<n><TAB><text>`
# record per line, <n> being the text's line number in --file. Writes the texts
# to <out>, one per line, in order. SETTER-GLOBAL PG_NF_NUM[k]: the number of
# the k-th record. The split is at the FIRST tab, by expansion, so a text may
# start with a tab; the number is bounded and matched as text. 1 on a record
# with no tab or a number outside ^[1-9][0-9]{0,9}$.
_pg_names_file_split() {
  local LC_ALL=C line n k=0
  PG_NF_NUM=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *$'\t'*) ;;
      *) return 1 ;;
    esac
    n="${line%%$'\t'*}"
    [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    k=$((k + 1))
    PG_NF_NUM[k]="$n"
    printf '%s\n' "${line#*$'\t'}"
  done < "$1" > "$2"
}

# _pg_names: the names check.
_pg_names() {
  local text="${PG_ARG[file]}" loc rc name cites="" wnums cnums all n count=0 list="" vrc=0 mapped=""
  _pg_denylist_locate
  case "$PG_DL_STATE" in
    ok) ;;
    moved) _pg_hold names denylist-moved; return ;;
    missing) _pg_hold names denylist-missing; return ;;
    missing-unrecorded) _pg_hold names denylist-missing-unrecorded; return ;;
    *) _pg_hold names gate-error "$PG_DL_DETAIL"; return ;;
  esac
  if ! _pg_entries; then
    _pg_hold names gate-error scan-failed
    return
  fi
  if [ -z "$PG_ENTRIES" ]; then
    _pg_hold names denylist-empty
    return
  fi
  # Explicit candidates, never the ambient locale.
  if ! utf8_locale_resolve "${_PG_LOCALES[@]}"; then
    _pg_hold names no-utf8-locale
    return
  fi
  loc="$UTF8_LOCALE"
  if [ -n "${PG_ARG[names-file]+x}" ]; then
    # The records are scanned in place of --file; hits are reported at their numbers.
    if [ ! -f "${PG_ARG[names-file]}" ] || [ ! -r "${PG_ARG[names-file]}" ]; then
      _pg_hold names gate-error file-unreadable
      return
    fi
    if ! pg_tmp; then
      _pg_hold names gate-error scan-failed
      return
    fi
    text="$PG_TMP"
    if ! _pg_names_file_split "${PG_ARG[names-file]}" "$text"; then
      _pg_hold names gate-error names-file-malformed
      return
    fi
    mapped=1
  elif [ ! -f "$text" ] || [ ! -r "$text" ]; then
    _pg_hold names gate-error file-unreadable
    return
  fi
  for n in "$PG_DL_PATH" "$text"; do
    rc=0
    _pg_utf8_valid "$loc" "$n" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 1 ]; then _pg_hold names gate-error invalid-utf8; else _pg_hold names gate-error scan-failed; fi
      return
    fi
  done
  if [ -z "$PG_DL_RECORDED" ] && [ -z "${PG_ARG[no-record]+x}" ]; then
    if ! _pg_record_write; then
      _pg_hold names gate-error "$PG_RECORD_FAULT"
      return
    fi
  fi
  if ! _pg_roster "$loc"; then
    _pg_hold names gate-error scan-failed
    return
  fi
  if [ -z "$PG_ROSTER" ]; then
    _pg_hold names denylist-empty roster-empty
    return
  fi
  # The verdict is the shared predicate's (its output, which names entries, is
  # discarded); the lines are found here with the same two matches.
  LC_ALL="$loc" potholes_private_name_hits --names-fd 3 "$text" 3< <(printf '%s\n' "$PG_ROSTER") >/dev/null 2>&1 || vrc=$?
  if [ "$vrc" -gt 1 ]; then
    _pg_hold names gate-error scan-failed
    return
  fi
  while IFS= read -r name; do
    cites+="(${name} Issue-"$'\n'
  done <<<"$PG_ROSTER"
  rc=0
  wnums="$(_pg_line_numbers "$loc" -naiwF "$text" <<<"$PG_ROSTER")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    _pg_hold names gate-error scan-failed
    return
  fi
  rc=0
  cnums="$(_pg_line_numbers "$loc" -naiF "$text" <<<"${cites%$'\n'}")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    _pg_hold names gate-error scan-failed
    return
  fi
  all="$(printf '%s\n%s\n' "$wnums" "$cnums" | LC_ALL=C sort -n -u)"
  if [ -n "$mapped" ]; then
    # grep's line k is the k-th record: report its number, each once, ascending.
    wnums=""
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if ! [[ "$n" =~ ^[1-9][0-9]*$ ]] || [ -z "${PG_NF_NUM[$n]:-}" ]; then
        _pg_hold names gate-error scan-failed
        return
      fi
      wnums+="${PG_NF_NUM[$n]}"$'\n'
    done <<<"$all"
    all="$(printf '%s' "$wnums" | LC_ALL=C sort -n -u)"
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
      _pg_hold names gate-error scan-failed
      return
    fi
    count=$((count + 1))
    list+="${list:+,}$n"
  done <<<"$all"
  if { [ "$vrc" -eq 1 ] && [ "$count" -eq 0 ]; } || { [ "$vrc" -eq 0 ] && [ "$count" -gt 0 ]; }; then
    _pg_hold names gate-error scan-disagree
    return
  fi
  if [ "$count" -gt 0 ]; then
    _pg_hold names names-hit "hits=$count lines=$list"
    return
  fi
  _pg_pass names
}

# _pg_record_main: record-denylist. The list must be usable (a missing,
# unreadable or zero-entry list is a gate-error), --expect must name the
# current path, and the session must not be marked unattended. It replaces the
# record whatever it holds, so a malformed record has a way out.
_pg_record_main() {
  local expect
  _pg_parse record "$@" || return 2
  _pg_item || return 2
  if devagent_unattended; then
    printf 'post-gate: record-denylist refused unattended\n' >&2
    return 1
  fi
  if [ -n "$PG_FAULT" ]; then
    _pg_hold names gate-error "$PG_FAULT"
    return
  fi
  if ! _pg_denylist_path; then
    _pg_hold names gate-error "$PG_DL_DETAIL"
    return
  fi
  if [ ! -f "$PG_DL_PATH" ] || [ ! -r "$PG_DL_PATH" ] || ! _pg_entries; then
    _pg_hold names gate-error list-missing
    return
  fi
  if [ -z "$PG_ENTRIES" ]; then
    _pg_hold names gate-error list-empty
    return
  fi
  if [ -n "${PG_ARG[expect]+x}" ]; then
    expect="$(expand_tilde "${PG_ARG[expect]}")"
    _pg_posix_path "$expect"
    if ! _pg_same_file "$PG_POSIX" "$PG_DL_PATH"; then
      printf 'post-gate: record-denylist refused expect-mismatch\n' >&2
      return 1
    fi
  fi
  if ! _pg_record_write; then
    _pg_hold names gate-error "$PG_RECORD_FAULT"
    return
  fi
}

# _pg_status_main: denylist-status. One token on stdout — absent, missing,
# moved, empty, unrecorded or present — and nothing is ever recorded. 1 when
# row 1 cannot be told (the config, the path's type, the record file).
_pg_status_main() {
  if [ "$#" -ne 0 ]; then
    _pg_usage "denylist-status takes no argument"
    return 2
  fi
  _pg_denylist_locate
  case "$PG_DL_STATE" in
    ok) ;;
    moved) printf 'moved\n'; return 0 ;;
    missing) printf 'missing\n'; return 0 ;;
    missing-unrecorded) printf 'absent\n'; return 0 ;;
    *)
      printf 'post-gate.sh: denylist-status: cannot tell (%s)\n' "$PG_DL_DETAIL" >&2
      return 1
      ;;
  esac
  if ! _pg_entries; then
    printf 'post-gate.sh: denylist-status: cannot tell (scan-failed)\n' >&2
    return 1
  fi
  if [ -z "$PG_ENTRIES" ]; then
    printf 'empty\n'
    return 0
  fi
  # An empty roster is `empty` too; without a UTF-8 locale the subtraction
  # cannot be made, and the names check reports that itself.
  if utf8_locale_resolve "${_PG_LOCALES[@]}"; then
    if ! _pg_roster "$UTF8_LOCALE"; then
      printf 'post-gate.sh: denylist-status: cannot tell (scan-failed)\n' >&2
      return 1
    fi
    if [ -z "$PG_ROSTER" ]; then
      printf 'empty\n'
      return 0
    fi
  fi
  if [ -n "$PG_DL_RECORDED" ]; then printf 'present\n'; else printf 'unrecorded\n'; fi
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
    names) _pg_names ;;
    permission) _pg_permission ;;
    tracker) _pg_tracker ;;
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

# post_gate_record_denylist <flags of `record-denylist`>
post_gate_record_denylist() { _pg_entry _pg_record_main "$@"; }

# post_gate_denylist_status
post_gate_denylist_status() { _pg_entry _pg_status_main "$@"; }

# post_gate_check <permission|tracker|names|review> <flags of `check`>
post_gate_check() { _pg_entry _pg_check_main "$@"; }

# post_gate_run <flags of `run`>: the full gate. 0 when all four checks passed.
post_gate_run() { _pg_entry _pg_run_main "$@"; }

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
