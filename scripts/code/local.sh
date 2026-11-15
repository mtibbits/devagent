#!/usr/bin/env bash
# scripts/code/local.sh — the local code backend (#1016): the §9.2 code verbs
# answered with git alone, for a project that pushes nothing and has no forge.
# A merge request (MR) is one record file under the source repo's git common
# dir, named by a `local:` reference; the spec's §9.2 holds the reference,
# record and state grammar.
#
# Verb (each also takes --key <v>, once, and ignores it)  stdout     exit
#   push-branch <remote> <branch>                 nothing           0, always
#   create-mr <repo> <title> <body-file> <head> <base> [--draft]
#                                                 the reference     0; 1 not a repository,
#                     head or base not a local branch, a merged or closed record,
#                     a failed write, git too old; 5 an unreadable record
#   mr-state <ref>                                open|merged|closed  0; 1 not a reference,
#                     no record, git could not answer; 5 a malformed record
#   mr-comments <ref>                             ## Comments (0)   as mr-state
#   branch-exists <repo> <branch>                 nothing           0 exists; 1 does not;
#                                                                   2 cannot tell
#   merged-pr-head <repo> <branch>                nothing           0 merged; 1 not merged,
#                                                                   or no record; 2 cannot tell
#   merge-mr, issue-mrs, mr-checks, mr-view       nothing           78, whatever the arguments
#
# Exit 2 is usage (a wrong argument count, an unknown verb, a bad option), plus
# "cannot tell" for branch-exists and merged-pr-head. On a non-zero exit stdout
# is empty. Options follow a verb's positionals, which are taken by count and
# never read as options. <body-file> is not read: the body stays in mr.md.
#
# The repo is named only by argument (git -C <repo>, or git --git-dir=<common-dir>
# for a reference); the script never changes directory, never reads HEAD or a
# working-tree file, and unsets GIT_DIR, GIT_WORK_TREE and GIT_COMMON_DIR first,
# because an exported GIT_DIR overrides -C. Only create-mr writes. git is read by
# exit code: 0 yes, 1 no, anything else "cannot tell", which fails the verb.
# All git calls go through $DEVAGENT_GIT so tests can stub.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

: "${DEVAGENT_GIT:=git}"

# shellcheck source=../lib/backend-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/backend-common.sh"

usage() {
  cat >&2 <<'EOF'
usage: code/local.sh <verb> [args...] [--key <value>]
verbs:
  push-branch    <remote> <branch>
  create-mr      <repo> <title> <body-file> <head> <base> [--draft]
  mr-state       <ref>
  mr-comments    <ref>
  branch-exists  <repo> <branch>
  merged-pr-head <repo> <branch>
  merge-mr, issue-mrs, mr-checks, mr-view: not implemented (exit 78)
EOF
  exit 2
}

# _opts <allow-draft> [args...]: the options after a verb's positionals. Each
# verb takes --key <value> once; create-mr also takes --draft. Sets DRAFT.
DRAFT=0
_opts() {
  local allow_draft="$1" key_seen=0; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --key)
        { [ "$key_seen" -eq 0 ] && [ $# -ge 2 ] && [ -n "$2" ]; } || usage
        key_seen=1; shift 2 ;;
      --draft)
        { [ "$allow_draft" -eq 1 ] && [ "$DRAFT" -eq 0 ]; } || usage
        DRAFT=1; shift ;;
      *) usage ;;
    esac
  done
}

# _scan_key [args...]: for the verbs that take any arguments, apply only the
# --key clauses (no value, an empty one, --key=<v>, a second --key).
_scan_key() {
  local key_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --key)
        { [ "$key_seen" -eq 0 ] && [ $# -ge 2 ] && [ -n "$2" ]; } || usage
        key_seen=1; shift 2 ;;
      --key=*) usage ;;
      *) shift ;;
    esac
  done
}

# _git_rc <git args...>: run git quietly; print nothing, return its exit code.
_git_rc() {
  local rc=0
  "$DEVAGENT_GIT" "$@" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# _branch_rc <repo> <branch>: 0 the local branch exists, 1 it does not, else git's code.
_branch_rc() {
  _git_rc -C "$1" rev-parse --verify --quiet "refs/heads/$2^{commit}"
}

cmd_branch_exists() {
  local rc=0
  _branch_rc "$1" "$2" || rc=$?
  case "$rc" in
    0|1) exit "$rc" ;;
    *) echo "git could not answer for $1 (exit $rc)" >&2; exit 2 ;;
  esac
}

# _is_abs <path>: one line, absolute (/… or X:/…).
_is_abs() {
  [[ "$1" != *$'\n'* ]] && [[ "$1" == /* || "$1" =~ ^[A-Za-z]:/ ]]
}

# _common_dir <repo>: set CDIR to git's own common-dir line for <repo>, its drive
# letter (Git Bash) upper-cased, so one repo has one reference however it is spelled.
CDIR=""
_common_dir() {
  local out rc=0
  out="$("$DEVAGENT_GIT" -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then echo "not a git repository: $1" >&2; exit 1; fi
  out="${out%$'\r'}"
  # An older git echoes the unknown option back on a line of its own.
  _is_abs "$out" || { echo "git 2.31 or newer is needed (rev-parse --path-format)" >&2; exit 1; }
  [[ "$out" =~ ^[a-z]:/ ]] && out="$(printf '%s' "${out:0:1}" | tr '[:lower:]' '[:upper:]')${out:1}"
  CDIR="$out"
}

# _need_branch <repo> <branch>: exit 1 unless refs/heads/<branch> exists.
_need_branch() {
  local rc=0
  [ -n "$2" ] || { echo "not a local branch: $2" >&2; exit 1; }
  _branch_rc "$1" "$2" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "not a local branch: $2" >&2; exit 1 ;;
    *) echo "git could not answer for $1 (exit $rc)" >&2; exit 1 ;;
  esac
}

# _write_record <path> <head> <base> <head_sha> <title>: a temp file in the same
# folder by a plain redirect, then one rename (up to 10 tries, 0.1 s apart).
_write_record() {
  local path="$1" dir tmp i
  dir="${path%/*}"
  tmp="$dir/.tmp-$$-${path##*/}"
  if mkdir -p "$dir" 2>/dev/null \
     && printf 'version: 1\nstate: open\nhead: %s\nbase: %s\nhead_sha: %s\nmerge_commit: -\ntitle: %s\n' \
          "$2" "$3" "$4" "$5" > "$tmp" 2>/dev/null; then
    for (( i = 0; i < 10; i++ )); do
      mv -f "$tmp" "$path" 2>/dev/null && return 0
      sleep 0.1
    done
  fi
  rm -f "$tmp" 2>/dev/null || true
  echo "cannot write the local MR record at $path" >&2
  exit 1
}

cmd_create_mr() {
  local repo="$1" title="$2" head="$3" base="$4" enc sha
  _common_dir "$repo"
  _need_branch "$repo" "$head"
  _need_branch "$repo" "$base"
  sha="$("$DEVAGENT_GIT" -C "$repo" rev-parse --verify --quiet "refs/heads/$head^{commit}" 2>/dev/null)" \
    || { echo "git could not answer for $repo (exit $?)" >&2; exit 1; }
  title="${title//[$'\r\n\t']/ }"
  enc="$(bc_urlenc "$head")"
  _write_record "$CDIR/devagent/local-mr/$enc" "$head" "$base" "$sha" "$title"
  [ "$DRAFT" -eq 1 ] && echo "draft: not applicable (local code backend)" >&2
  printf 'local:%s#%s\n' "$(bc_urlenc "$CDIR")" "$enc"
}

# --- the reference, the record and the state -----------------------------------

# _decode <enc>: set DEC to <enc> percent-decoded (the caller has checked its shape).
DEC=""
_decode() { printf -v DEC '%b' "${1//%/\\x}"; }

# _parse_ref <ref>: set RDIR (the common dir), RENC (the encoded branch) and RHEAD
# (the branch), or exit 1. Valid only in D-ref's shape, with each part canonical
# (re-encoding it gives it back byte for byte), an absolute directory, and a
# branch that is neither . nor ..
RDIR="" RENC="" RHEAD=""
_parse_ref() {
  local ref="$1" body enc_dir unit='([A-Za-z0-9._~-]|%[0-9A-F]{2})+'
  body="${ref#local:}"
  if [ "$body" != "$ref" ] && [[ "$body" =~ ^($unit)#($unit)$ ]] && [[ "$body" != *%00* ]]; then
    enc_dir="${body%%#*}"; RENC="${body#*#}"
    _decode "$enc_dir"; RDIR="$DEC"
    _decode "$RENC"; RHEAD="$DEC"
    if [ "$(bc_urlenc "$RDIR")" = "$enc_dir" ] && [ "$(bc_urlenc "$RHEAD")" = "$RENC" ] \
       && _is_abs "$RDIR" && [ "$RHEAD" != . ] && [ "$RHEAD" != .. ]; then
      return 0
    fi
  fi
  echo "not a local MR reference: $ref" >&2
  exit 1
}

# _read_record <path> <head> <exit>: read D-rec into REC_<key>; a missing record
# exits 1, a malformed one exits <exit> (5 for the reference verbs).
_read_record() {
  local path="$1" head="$2" bad="$3" line key val seen=" " k
  REC_version="" REC_state="" REC_head="" REC_base="" REC_head_sha="" REC_merge_commit="" REC_title=""
  [ -e "$path" ] || { echo "no local MR record at $path" >&2; exit 1; }
  _bad_record() { echo "malformed local MR record at $path: $1" >&2; exit "$bad"; }
  [ -f "$path" ] && [ -r "$path" ] || _bad_record "not a readable file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" == *": "* ]] || _bad_record "a line is not 'key: value'"
    key="${line%%: *}"; val="${line#*: }"
    case "$key" in
      version|state|head|base|head_sha|merge_commit|title) ;;
      *) _bad_record "unknown key '$key'" ;;
    esac
    [[ "$seen" != *" $key "* ]] || _bad_record "repeated key '$key'"
    seen+="$key "
    printf -v "REC_$key" '%s' "$val"
  done < "$path"
  for k in version state head base head_sha merge_commit title; do
    [[ "$seen" == *" $k "* ]] || _bad_record "missing key '$k'"
  done
  [ "$REC_version" = 1 ] || _bad_record "version is not 1"
  case "$REC_state" in open|merged|closed) ;; *) _bad_record "bad state '$REC_state'" ;; esac
  [[ "$REC_head_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || _bad_record "bad head_sha"
  [[ "$REC_merge_commit" =~ ^(-|[0-9a-f]{40}|[0-9a-f]{64})$ ]] || _bad_record "bad merge_commit"
  [ "$REC_head" = "$head" ] || _bad_record "head is not the record's branch"
}

# _rc <git args...>: run git quietly against the common dir $RDIR; return its code.
_rc() { _git_rc --git-dir="$RDIR" "$@"; }

# _state <cannot-tell exit>: set STATE from REC_* by D-state. A git answer other
# than yes or no exits <cannot-tell exit>.
STATE=""
_state() {
  local fail="$1" rc
  _cannot() { echo "git could not answer for $RDIR (exit $1)" >&2; exit "$fail"; }
  if [ "$REC_state" = merged ]; then STATE=merged; return 0; fi
  # Ancestor: the head_sha commit exists, the base resolves, and is-ancestor says yes.
  rc=0; _rc rev-parse --verify --quiet "$REC_head_sha^{commit}" || rc=$?
  case "$rc" in 0|1) ;; *) _cannot "$rc" ;; esac
  if [ "$rc" -eq 0 ]; then
    rc=0; _rc rev-parse --verify --quiet "refs/heads/$REC_base^{commit}" || rc=$?
    case "$rc" in 0|1) ;; *) _cannot "$rc" ;; esac
    if [ "$rc" -eq 0 ]; then
      rc=0; _rc merge-base --is-ancestor "$REC_head_sha" "refs/heads/$REC_base" || rc=$?
      case "$rc" in
        0) STATE=merged; return 0 ;;
        1) ;;
        *) _cannot "$rc" ;;
      esac
    fi
  fi
  if [ "$REC_state" = closed ]; then STATE=closed; return 0; fi
  rc=0; _rc rev-parse --verify --quiet "refs/heads/$REC_head^{commit}" || rc=$?
  case "$rc" in
    0) STATE=open ;;
    1) STATE=closed ;;
    *) _cannot "$rc" ;;
  esac
}

cmd_mr_state() {
  _parse_ref "$1"
  _read_record "$RDIR/devagent/local-mr/$RENC" "$RHEAD" 5
  _state 1
  printf '%s\n' "$STATE"
}

cmd_mr_comments() {
  _parse_ref "$1"
  _read_record "$RDIR/devagent/local-mr/$RENC" "$RHEAD" 5
  bc_emit_comments_header 0
}

[ $# -ge 1 ] || usage
verb="$1"; shift
case "$verb" in
  push-branch)
    _scan_key "$@"
    echo "push: not applicable (local code backend)" >&2
    ;;
  merge-mr|issue-mrs|mr-checks|mr-view)
    _scan_key "$@"
    echo "$verb: not implemented by the local code backend" >&2
    exit 78
    ;;
  create-mr)
    [ $# -ge 5 ] || usage
    _opts 1 "${@:6}"
    cmd_create_mr "$1" "$2" "$4" "$5"
    ;;
  mr-state|mr-comments)
    [ $# -ge 1 ] || usage
    _opts 0 "${@:2}"
    "cmd_${verb//-/_}" "$1"
    ;;
  branch-exists)
    [ $# -ge 2 ] || usage
    _opts 0 "${@:3}"
    cmd_branch_exists "$1" "$2"
    ;;
  *) usage ;;
esac
