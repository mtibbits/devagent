#!/usr/bin/env bash
# scripts/preship-deferred.sh — #1097: what the preship verifier asks about an
# acceptance criterion that a required CI check meets only after ship ("the check is
# green at the merged head"). It cannot run that check, so it verifies what can be
# read beforehand and records the criterion as deferred; mergemr then merges only
# when the check succeeded.
#
#   usage: preship-deferred.sh <project> <Issue-N>
#          preship-deferred.sh <project> <Issue-N> static <check> <test-file> <test-name>
#          preship-deferred.sh <project> <Issue-N> transcript <test-file>
#
# Positional arguments only: there are no options, so a check or test name may start
# with `-`.
#
# WHAT IT READS. Config, the issue's state and commits of the issue tree
# (active_tree_resolve): the pinned head `preship_pin_head`, the commit the verifier
# was handed, and `baseline_sha`. Never the working tree, the index or HEAD: a file
# is read from the pinned commit's tree. `transcript` reads one file of
# <issue-dir>/evidence/ and no commit. It makes no network call and runs no backend:
# git reads go through _selfcert_git (lib/selfcert.sh), so in a partial clone a
# missing object is a failed read, never a fetch. It writes nothing but a temporary
# directory, which it removes.
#
# STDOUT, one spelling each.
#   No subcommand:
#     required checks: <name>[; <name>...]     the project's required_checks, or
#     required checks: (none)                  with none it stops here, exit 0: it
#                                              needs no pin
#     code backend: <backend> (mr-checks: yes|no)
#                                              whether the code backend can report
#                                              checks (lib/ci.sh ci_checks_capable).
#                                              `no` is the class mergemr stops on with
#                                              CI NOT CHECKED: nothing will check the
#                                              deferred criterion at the merge
#     self-certification warning: <paths> changed in <base7>..<pin7>; mergemr stops [!] until an operator records a review in .devagent-selfcert-ack
#     self-certification: nothing self-certifying changed in <base7>..<pin7>
#                                              one of the two: lib/selfcert.sh's scan
#                                              of baseline_sha..preship_pin_head, with
#                                              the arguments mergemr gives it. The
#                                              warning fails nothing here.
#   static <check> <test-file> <test-name>: one line.
#     deferred to CI at merge: <check>         exit 0: what can be read of the
#                                              criterion before ship holds at the pin
#     static check failed: <reason>            exit 1. <reason> is the first of:
#       '<check>' is not in [project.<p>] required_checks
#           Byte for byte. It proves the name is listed, not what the check runs.
#       <test-file> is not selected by the job: it must be tests/<name>.bats
#           The job runs `gitbash-tagged.sh select tests`, which globs tests/*.bats: a
#           subdirectory, another directory or a dot-file is never run.
#       <test-file> does not exist at <pin7>
#       <test-file> carries no gitbash tag line at <pin7>
#           The file as the pinned commit holds it, alone in a temporary directory,
#           must be listed by scripts/ci/gitbash-tagged.sh select, the plugin's copy of
#           the job's selector. A tag line the selector calls malformed is none.
#       no test named '<test-name>' in <test-file> at <pin7>
#       test '<test-name>' in <test-file> at <pin7> is named twice     (or `<n> times`)
#           A test is a line `@test "<n>" {` or `@test '<n>' {`, trailing blanks aside.
#           <test-name> is <n> as the source spells it or, for a double-quoted <n>, as
#           bats displays it (`C:\\x` in the source is `C:\x`). Its body runs to the
#           next line that is exactly `}`. A test written on one line is not read.
#       <test-file>:<line>: Git Bash skip guard in '<test-name>': <the line, at most 120 characters>
#           A line of the body skips on Git Bash, or calls a function of the file that
#           does. The predicate and what it does not see are described at its code.
#     A CR at a line's end is dropped before any of it is read. In a message a control
#     character of an argument is shown as `?`.
#   transcript <test-file>: one line. The fallback where no CI check can stand as
#   the evidence: a Git Bash run recorded by hand, at the pinned head.
#     transcript accepted: evidence/<name> is at the pinned head <pin40>      exit 0
#     transcript check failed: <reason>        exit 1. <reason> is the first of:
#       no evidence/<YYYY-MM-DD>-gitbash-<stem>-<sha>.txt is in the issue directory for the pinned head <pin7>
#       evidence/<name> is named for another head, not the pinned head <pin7>
#       evidence/<name> line 1 is not a full commit id: <the line>
#       evidence/<name> line 1 records head <sha7>, not the pinned head <pin7>
#       evidence/<name> line 2 is not a Git Bash uname line (MINGW... or MSYS...): <the line>
#           The transcript is a regular file <issue-dir>/evidence/<name>, <name> being
#           <YYYY-MM-DD>-gitbash-<stem>-<sha>.txt: <stem> the test file's basename
#           without .bats, compared as text; <sha> 7 to 40 lower-case hex digits that
#           begin the pinned head. Of several, the lexicographically last name is the
#           one read, and named, whatever the others hold. Its line 1 is the head the
#           run was at, 40 hex digits, alone or after `sha: `; its line 2 is that
#           host's `uname -a`, alone or after `uname: `, starting MINGW or MSYS. CRs
#           are dropped from both. Nothing else of the file is read.
#
# EXITS
#   0   the lines above; or the check passed
#   1   the check failed (a `static` or `transcript` call only)
#   2   usage, or could not run: stdout is empty and stderr says why, as
#       `preship-deferred: <why>`. A library's own failure (a bad required_checks
#       value, an unusable tree) keeps its message and is followed by
#       `preship-deferred: could not run (exited <rc> ...)`. Never 1: a check that
#       could not run has not failed.
#   11  the issue is quarantined (the marker; no tracker read)
set -euo pipefail
export LC_ALL=C     # file bytes are matched as bytes: a stray lead byte cannot hide a line

usage="usage: preship-deferred.sh <project> <Issue-N> [static <check> <test-file> <test-name> | transcript <test-file>]"
_usage() { printf '%s\n' "$usage" >&2; exit 2; }

case "$#:${3:-}" in
  2:) ;;
  6:static|4:transcript) ;;
  *) _usage ;;
esac
for _a in "$@"; do [ -n "$_a" ] || _usage; done
project="$1" issue="$2" sub="${3:-}"

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=lib/ci.sh
. "$DEVAGENT_ROOT/scripts/lib/ci.sh"            # ci_checks_capable; nothing here calls a backend
# shellcheck source=lib/selfcert.sh
. "$DEVAGENT_ROOT/scripts/lib/selfcert.sh"

: "${DEVAGENT_GIT:=git}"

TMP=""
# _exit <rc>: the only way out once the trap is armed.
_exit() {
  trap - EXIT
  [ -z "$TMP" ] || rm -rf "$TMP"
  exit "$1"
}
# _cnr <why>: could not run. Nothing was printed yet: every line is printed at the end.
_cnr() { printf 'preship-deferred: %s\n' "$1" >&2; _exit 2; }
# Any other exit (a library's die, an errexit) is "could not run" too: a library dies
# with 1, which here would read as a failed check. The one exit that passes through is
# the quarantine marker's own 11.
GUARDING=0
# shellcheck disable=SC2317  # invoked by the EXIT trap
_on_exit() {
  local rc=$?
  if [ "$GUARDING" -eq 1 ] && [ "$rc" -eq 11 ]; then _exit 11; fi
  printf 'preship-deferred: could not run (exited %s before the check was complete)\n' "$rc" >&2
  _exit 2
}
trap _on_exit EXIT

config_load
config_is_project "$project" || _cnr "unknown project '${project//[[:cntrl:]]/?}'"
GUARDING=1
quarantine_guard_marker "preship-deferred" "$project" "$issue"
GUARDING=0

active_resolve_issue_src "$project" "$issue"    # setter-globals; dies on a malformed id
issue_dir="$(issue_context_dir "$project" "$issue")" \
  || _cnr "could not derive the issue directory for $issue"
[ -d "$issue_dir" ] || _cnr "no issue directory for $issue: $issue_dir"

required_checks_resolve "$project"              # REQUIRED_CHECKS, REQUIRED_CHECKS_PATHS; dies on a bad value

# _state <key>: the issue's state value, CR-stripped, empty when unset.
_state() {
  local v
  v="$(state_ctx_get "$project" "$1" "$issue" 2>/dev/null || true)"
  v="${v//$'\r'/}"
  case "$v" in null|'""') v="" ;; esac
  printf '%s' "$v"
}

# _need_pin: sets PIN, the pinned head, a full commit id. Whether it is a commit of
# the tree is the reader's to say: selfcert_paths and _blob_at each name the commit
# they could not read.
_need_pin() {
  PIN="$(_state preship_pin_head)"
  [ -n "$PIN" ] || _cnr "no pinned head is recorded for $issue (preship_pin_head); the preship wrapper pins the head before it dispatches the verifier"
  [[ "$PIN" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || _cnr "preship_pin_head '${PIN//[[:cntrl:]]/?}' is not a full commit id"
}
# _need_tree: sets TREE, the issue tree, whose repository holds the commits.
_need_tree() {
  active_tree_resolve "$project" "$issue"       # setter-globals; never $( ... )
  TREE="$ACTIVE_TREE_DIR"
}

# ---- no subcommand: required checks, capability, self-certification ----------------

if [ -z "$sub" ]; then
  if [ "${#REQUIRED_CHECKS[@]}" -eq 0 ]; then
    printf 'required checks: (none)\n'
    _exit 0
  fi
  names="$(printf '; %s' "${REQUIRED_CHECKS[@]}")"
  ci_checks_capable "$project" || _cnr "$CI_CAPABLE_WHY"
  _need_pin
  _need_tree
  base="$(_state baseline_sha)"
  [ -n "$base" ] || _cnr "no baseline_sha is recorded for $issue"
  sc_rc=0
  selfcert_paths "$TREE" "$base" "$PIN" \
    ${REQUIRED_CHECKS_PATHS[@]+"${REQUIRED_CHECKS_PATHS[@]}"} || sc_rc=$?
  [ "$sc_rc" -eq 0 ] || _cnr "${SELFCERT_WHY:-the self-certification scan exited $sc_rc}"
  printf 'required checks: %s\n' "${names#; }"
  printf 'code backend: %s (mr-checks: %s)\n' "$CI_CAPABLE_BACKEND" "$CI_CAPABLE"
  if [ "${#SELFCERT_PATHS[@]}" -gt 0 ]; then
    printf 'self-certification warning: %s changed in %s..%s; mergemr stops [!] until an operator records a review in .devagent-selfcert-ack\n' \
      "$SELFCERT_LIST" "${base:0:7}" "${PIN:0:7}"
  else
    printf 'self-certification: nothing self-certifying changed in %s..%s\n' "${base:0:7}" "${PIN:0:7}"
  fi
  _exit 0
fi

# _fail <reason>: the check failed: its one line, exit 1.
_fail() { printf '%s check failed: %s\n' "$sub" "$1"; _exit 1; }
# _show <text>: sets SHOWN to <text> for a message: outer blanks trimmed, each control
# character as `?`, at most 120 characters.
_show() {
  local t="$1" cut
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  t="${t//[[:cntrl:]]/?}"
  if [ "${#t}" -gt 120 ]; then
    cut="${t:0:120}"
    # In the C locale that is 120 bytes. When the next byte continues a UTF-8
    # character the cut split it: drop the bytes of it that made it in.
    if [[ "${t:120:1}" == [$'\x80'-$'\xbf'] ]]; then
      while [[ "$cut" == *[$'\x80'-$'\xbf'] ]]; do cut="${cut%?}"; done
      cut="${cut%?}"
    fi
    t="$cut"
  fi
  SHOWN="$t"
}

# ---- static: the Git Bash skip-guard predicate ---------------------------------------
#
# The question for a `skip` is its direction: does it run when the host IS Git Bash? A
# line is read as code only: quoted text and comments are masked first (_mask). A
# `skip` command word (not part of a longer word, followed by a blank, `;` or the end
# of the line) TRIPS when
#   - the code before it on its line names Git Bash (GB_TOKEN_RE, any case), unless
#     that code is one of the forms below, in which skip runs only off Git Bash; or
#   - it stands under a case arm whose pattern names a Git Bash value (MINGW*|MSYS*)
#     that an earlier line opened and no `;;` has closed.
# Not Git Bash, so no trip (the whole code before the skip must be the form):
#   <is> || skip        <is not> && skip        (also `|| {` and `&& {`)
#   if <is not>; then skip
#   case ... <Git Bash arm>) ;; ... <another arm>) skip      (the Git Bash arm empty
#                         and closed by `;;`; no `;&`, `;;&` or `esac` before the skip)
# where, with <v> a literal that starts with a Git Bash value (MINGW*, "msys",
# ^(MINGW|MSYS)), on either side:
#   <is>      is_git_bash    [ a = <v> ]    [[ a == <v> ]]    [[ a =~ <v> ]]
#   <is not>  ! <is>         [ a != <v> ]   [[ a != <v> ]]    [ ! a = <v> ]
# Everything else that names Git Bash before a skip trips, whichever way it points: a
# guard this cannot read fails the check rather than pass it. So `[ "$(uname -s)" =
# Linux ] || skip` trips (it does skip on Git Bash), and so does a compound test.
# One level of indirection: a call to a column-0 function of the same file (`name() {`
# or `function name {`) one of whose own lines trips is a trip too.
# KNOWN MISSES, by design: a guard spread over lines (`if is_git_bash; then` / `skip`)
# and a helper that calls a helper (tests/preship-deferred.bats pins those two as
# misses); a helper from another file, a skip in setup(), and a skip whose test does
# not name Git Bash at all. The job itself fails a file whose every test skips.

GB_TOKEN_RE='is_git_bash|uname|ostype|mingw|msys|cygwin'    # read against lower case
GB_VALUE_RE='mingw|msys|cygwin'
GB_LITERAL_RE='^[*^(]*(mingw|msys|cygwin)'
WORD_END_RE='[[:alnum:]_-]$'
SKIP_AFTER_RE='^([[:space:];]|$)'
NOT_RE='^![[:space:]]+(.*)$'
DBR_RE='^\[\[[[:space:]]+(.*)[[:space:]]+\]\]$'
SBR_RE='^\[[[:space:]]+(.*)[[:space:]]+\]$'
CMP_RE='^([^[:space:]]+)[[:space:]]+(=|==|=~|!=)[[:space:]]+([^[:space:]]+)$'
SAFE_OP_RE='^(.*[^[:space:]])[[:space:]]*(\|\||&&)[[:space:]]*\{?$'
SAFE_IF_RE='^if[[:space:]]+(.*[^[:space:]])[[:space:]]*;[[:space:]]*then$'
SAFE_CASE_RE='(mingw|msys|cygwin)[^)]*\)[[:space:]]*;;'
ARM_RE='^[[:space:]]*\(?[^()]*\)$'
ARM_OPEN_RE='^[[:space:]]*\(?[^()]*(mingw|msys|cygwin)[^()]*\)'
ESAC_RE='(^|[^[:alnum:]_])esac([^[:alnum:]_]|$)'

# _mask <line>: sets MASK and MASKW, each <line> character for character up to an
# unquoted comment, which both drop.
#   MASK   every character inside '...', "..." or $'...' is `x`: what is left is code
#   MASKW  inside quotes only blanks and ()[];|&!=# are `x`: a quoted word stays one
#          word and keeps its text
_mask() {
  local s="$1" n=${#1} i c q="" prev="" m="" w=""
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "\\" ] && [ "$q" != "'" ] && ((i + 1 < n)); then
        m+=xx; w+=xx; i=$((i + 1))
      elif { [ "$q" = '"' ] && [ "$c" = '"' ]; } || { [ "$q" != '"' ] && [ "$c" = "'" ]; }; then
        q=""; m+="$c"; w+="$c"
      else
        m+=x
        case "$c" in
          [[:blank:]]|'('|')'|'['|']'|';'|'|'|'&'|'!'|'='|'#') w+=x ;;
          *) w+="$c" ;;
        esac
      fi
    else
      case "$c" in
        "\\") m+="$c${s:i+1:1}"; w+="$c${s:i+1:1}"; i=$((i + 1)); c=x ;;
        "'")  if [ "$prev" = '$' ]; then q=A; else q="'"; fi; m+="$c"; w+="$c" ;;
        '"')  q='"'; m+="$c"; w+="$c" ;;
        '#')  case "$prev" in ''|[[:blank:]]|';'|'&'|'|'|'(') break ;; esac
              m+="$c"; w+="$c" ;;
        *)    m+="$c"; w+="$c" ;;
      esac
    fi
    prev="$c"
  done
  MASK="$m"; MASKW="$w"
}

# _skip_words <mask>: sets SKIP_AT=( index ... ): where each skip command word starts.
_skip_words() {
  local m="$1" s="$1" off=0 before
  SKIP_AT=()
  while [[ "$s" == *skip* ]]; do
    before="${s%%skip*}"
    off=$((off + ${#before}))
    s="${s:${#before}+4}"
    if [[ ! "${m:0:off}" =~ $WORD_END_RE ]] && [[ "$s" =~ $SKIP_AFTER_RE ]]; then SKIP_AT+=("$off"); fi
    off=$((off + 4))
  done
}

# _gb_literal <word>: rc 0 when <word> (from MASKW) is a literal starting with a Git
# Bash value. A variable whose name holds one ("$MSYSTEM") is not a literal.
_gb_literal() {
  local v="$1"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  v="${v,,}"
  [[ "$v" =~ $GB_LITERAL_RE ]]
}

# _gb_polarity <test>: <test> is one test command (from MASKW). Sets POL to `is` (true
# exactly on Git Bash), `isnot` (true exactly off it) or empty (not one this reads).
_gb_polarity() {
  local c="$1" neg=0 inner a b
  POL=""
  c="${c#"${c%%[![:space:]]*}"}"
  c="${c%"${c##*[![:space:]]}"}"
  if [[ "$c" =~ $NOT_RE ]]; then neg=1; c="${BASH_REMATCH[1]}"; fi
  if [ "$c" != is_git_bash ]; then
    [[ "$c" =~ $DBR_RE || "$c" =~ $SBR_RE ]] || return 0
    inner="${BASH_REMATCH[1]}"
    if [[ "$inner" =~ $NOT_RE ]]; then neg=$((1 - neg)); inner="${BASH_REMATCH[1]}"; fi
    [[ "$inner" =~ $CMP_RE ]] || return 0
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[3]}"
    [ "${BASH_REMATCH[2]}" != '!=' ] || neg=$((1 - neg))
    _gb_literal "$a" || _gb_literal "$b" || return 0
  fi
  if [ "$neg" -eq 1 ]; then POL=isnot; else POL=is; fi
}

# _safe_form <code before a skip, from MASKW>: rc 0 when that code is one of the forms
# in which the skip runs only off Git Bash.
_safe_form() {
  local p="$1" lp tail
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  if [[ "$p" =~ $SAFE_OP_RE ]]; then
    tail="${BASH_REMATCH[2]}"
    _gb_polarity "${BASH_REMATCH[1]}"
    [[ "$tail" == '||' && "$POL" == is ]] || [[ "$tail" == '&&' && "$POL" == isnot ]]
    return
  fi
  if [[ "$p" =~ $SAFE_IF_RE ]]; then
    _gb_polarity "${BASH_REMATCH[1]}"
    [ "$POL" = isnot ]
    return
  fi
  # one case statement, still open, with no arm that falls through
  lp="${p,,}"
  [[ "$lp" == *';&'* || "$lp" =~ $ESAC_RE ]] && return 1
  [[ "$lp" =~ $SAFE_CASE_RE ]] || return 1
  tail="${lp##*;;}"
  [[ "$tail" =~ $ARM_RE ]] && [[ ! "$tail" =~ $GB_VALUE_RE ]]
}

# _line_trips <line>: rc 0 when <line> holds a skip that can run on Git Bash. It
# follows ARM_GB, whether a Git Bash case arm is open, across the lines of one body:
# the caller sets ARM_GB=0 before the first.
_line_trips() {
  local line="$1" at pre lw tail hit=1
  [[ "$line" == *skip* || "$line" == *")"* || "$line" == *";;"* || "$line" == *esac* ]] || return 1
  _mask "$line"
  if [[ "$MASK" == *skip* ]]; then
    _skip_words "$MASK"
    for at in ${SKIP_AT[@]+"${SKIP_AT[@]}"}; do
      pre="${MASKW:0:at}"
      if [[ "${pre,,}" =~ $GB_TOKEN_RE ]]; then
        _safe_form "$pre" || { hit=0; break; }
      elif [ "$ARM_GB" -eq 1 ]; then
        hit=0; break
      fi
    done
  fi
  # the arm this line leaves open: its last one, after the last `;;`
  lw="${MASKW,,}"
  tail="${lw##*;;}"
  if [[ "$tail" =~ $ARM_OPEN_RE ]]; then ARM_GB=1
  elif [[ "$lw" == *";;"* || "$lw" =~ $ESAC_RE ]]; then ARM_GB=0
  fi
  return "$hit"
}

# _body_end <first>: sets BODY_END to the index of the next line of LINES, from
# <first>, that is exactly `}` (trailing blanks aside), or to the line count.
_body_end() {
  local j l
  for ((j = $1; j < ${#LINES[@]}; j++)); do
    l="${LINES[j]}"
    [ "${l%"${l##*[![:space:]]}"}" != "}" ] || break
  done
  BODY_END="$j"
}

FN_RE='^([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*\(\)[[:blank:]]*\{(.*)$'
FN_KW_RE='^function[[:blank:]]+([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*(\(\))?[[:blank:]]*\{(.*)$'

# _helpers: fills SKIPPERS (name -> 1) with the column-0 functions of LINES one of
# whose own lines trips. A function is `name() {` or `function name {` with its body on
# the lines up to the next line that is exactly `}`, or on its one line.
_helpers() {
  local j=0 k l fn rest
  SKIPPERS=()
  while ((j < ${#LINES[@]})); do
    l="${LINES[j]}"
    j=$((j + 1))
    [[ "$l" == [A-Za-z_]*"{"* ]] || continue
    _mask "$l"
    if [[ "$MASK" =~ $FN_KW_RE ]]; then fn="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"
    elif [[ "$MASK" =~ $FN_RE ]]; then fn="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    else continue
    fi
    rest="${rest%"${rest##*[![:space:]]}"}"
    l="${l#*\{}"                                 # what follows the opening brace
    ARM_GB=0
    if [[ "$rest" == *"}" ]]; then
      # written on one line: its body is the text up to the last `}`
      ! _line_trips "${l%\}*}" || SKIPPERS[$fn]=1
      continue
    fi
    ! _line_trips "$l" || SKIPPERS[$fn]=1
    _body_end "$j"
    for ((k = j; k < BODY_END; k++)); do
      ! _line_trips "${LINES[k]}" || SKIPPERS[$fn]=1
    done
    j=$((BODY_END + 1))
  done
}

# _calls_skipper <line>: rc 0 when <line>'s code names a function of SKIPPERS.
_calls_skipper() {
  local line="$1" fn re masked=0
  for fn in ${SKIPPERS[@]+"${!SKIPPERS[@]}"}; do
    [[ "$line" == *"$fn"* ]] || continue
    if [ "$masked" -eq 0 ]; then _mask "$line"; masked=1; fi
    re="(^|[^[:alnum:]_])${fn}([^[:alnum:]_]|\$)"
    [[ ! "$MASK" =~ $re ]] || return 0
  done
  return 1
}

# _unescape <text>: sets UNESC to <text> as a double-quoted word displays: \\ \" \$ \`
# lose their backslash.
_unescape() {
  local s="$1" n=${#1} i c d out=""
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ "$c" = "\\" ] && ((i + 1 < n)); then
      d="${s:i+1:1}"
      case "$d" in "\\"|'"'|'$'|'`') out+="$d"; i=$((i + 1)); continue ;; esac
    fi
    out+="$c"
  done
  UNESC="$out"
}

# _blob_at <path>: copies <path> as the pinned commit holds it, CR-stripped, to a
# temporary directory of its own, and sets BLOB to the copy. Whether the file is there
# is read from the commit's tree, so a file that is there and cannot be read is never
# taken for one that is not (lib/selfcert.sh's rule): that is exit 2.
_blob_at() {
  local path="$1" F="${1//[[:cntrl:]]/?}" top out rc=0
  top="$(_selfcert_git -C "$TREE" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || top="$TREE"
  _selfcert_git -C "$top" rev-parse --verify --quiet "${PIN}^{commit}" >/dev/null 2>&1 \
    || _cnr "${PIN:0:7} is not a commit in $TREE"
  out="$(_selfcert_git --literal-pathspecs -C "$top" ls-tree "$PIN" -- "$path" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || _cnr "$F at ${PIN:0:7} cannot be read in $TREE (git ls-tree exited $rc)"
  out="${out%%$'\t'*}"                           # <mode> <type> <object id>
  [[ "$out" == *" blob "* ]] || _fail "$F does not exist at ${PIN:0:7}"
  TMP="$(mktemp -d)"
  mkdir "$TMP/sel"
  BLOB="$TMP/sel/${path##*/}"
  _selfcert_git -C "$top" cat-file blob "${out##* }" 2>/dev/null | tr -d '\r' >"$BLOB" || rc=$?
  [ "$rc" -eq 0 ] || _cnr "$F at ${PIN:0:7} cannot be read in $TREE (git cat-file exited $rc)"
}

if [ "$sub" = static ]; then
  check="$4" file="$5" name="$6"
  C="${check//[[:cntrl:]]/?}" F="${file//[[:cntrl:]]/?}" N="${name//[[:cntrl:]]/?}"   # as messages show them

  # 1. the check is one the project requires
  listed=0
  for c in ${REQUIRED_CHECKS[@]+"${REQUIRED_CHECKS[@]}"}; do
    [ "$c" != "$check" ] || listed=1
  done
  [ "$listed" -eq 1 ] || _fail "'$C' is not in [project.$project] required_checks"

  # 2. the job runs the file: it globs tests/*.bats and selects by the tag line
  [[ "$file" =~ ^tests/[^/.][^/]*\.bats$ ]] || _fail "$F is not selected by the job: it must be tests/<name>.bats"
  _need_pin
  _need_tree
  _blob_at "$file"
  sel_rc=0
  sel="$("${BASH:-bash}" "$DEVAGENT_ROOT/scripts/ci/gitbash-tagged.sh" select "$TMP/sel" 2>/dev/null)" || sel_rc=$?
  case "$sel_rc" in
    0)   [ "${sel//$'\r'/}" = "$BLOB" ] || _cnr "gitbash-tagged.sh select listed '${sel//[[:cntrl:]]/?}', not the one file it was given" ;;
    3|4) _fail "$F carries no gitbash tag line at ${PIN:0:7}" ;;      # none, or one the selector rejects
    *)   _cnr "gitbash-tagged.sh select exited $sel_rc" ;;
  esac

  # 3. exactly one test carries the name, as the source spells it or as bats shows it
  mapfile -t LINES <"$BLOB"
  hits=()
  for i in "${!LINES[@]}"; do
    l="${LINES[i]}"
    [[ "$l" == *@test* ]] || continue
    l="${l%"${l##*[![:space:]]}"}"
    [[ "$l" =~ ^[[:blank:]]*@test[[:blank:]]+(.*[^[:blank:]])[[:blank:]]+\{$ ]] || continue
    d="${BASH_REMATCH[1]}"
    case "$d" in
      \"*\") n="${d:1:${#d}-2}"; _unescape "$n" ;;
      \'*\') n="${d:1:${#d}-2}"; UNESC="$n" ;;
      *) continue ;;
    esac
    if [ "$name" = "$n" ] || [ "$name" = "$UNESC" ]; then hits+=("$i"); fi
  done
  case "${#hits[@]}" in
    0) _fail "no test named '$N' in $F at ${PIN:0:7}" ;;
    1) ;;
    2) _fail "test '$N' in $F at ${PIN:0:7} is named twice" ;;
    *) _fail "test '$N' in $F at ${PIN:0:7} is named ${#hits[@]} times" ;;
  esac

  # 4. no line of its body, and no helper it calls, skips on Git Bash
  declare -A SKIPPERS=()
  _helpers
  first=$((hits[0] + 1))
  _body_end "$first"
  ARM_GB=0
  for ((i = first; i < BODY_END; i++)); do
    if _line_trips "${LINES[i]}" || _calls_skipper "${LINES[i]}"; then
      _show "${LINES[i]}"
      _fail "$F:$((i + 1)): Git Bash skip guard in '$N': $SHOWN"
    fi
  done
  printf 'deferred to CI at merge: %s\n' "$C"
  _exit 0
fi

# ---- transcript: the fallback hand transcript -------------------------------------------

TX_SHA_RE='^(sha: )?([0-9a-f]{40})$'
TX_UNAME_RE='^(uname: )?(MINGW|MSYS)[^[:space:]]*[[:space:]].+'

# transcript <test-file>
testfile="$4"
stem="${testfile##*/}"
stem="${stem%.bats}"
[ -n "$stem" ] || _cnr "transcript: '${testfile//[[:cntrl:]]/?}' names no test file"
STEM="${stem//[[:cntrl:]]/?}"
_need_pin

# The candidates: <issue-dir>/evidence/<YYYY-MM-DD>-gitbash-<stem>-<sha>.txt, <stem>
# compared as text. `named` fit the form; `at_pin` also name the pinned head. The glob
# is sorted in the C locale, so the last entry is the lexicographically last name.
named=() at_pin=()
shopt -s nullglob
for p in "$issue_dir"/evidence/*; do
  n="${p##*/}"
  [ -f "$p" ] || continue
  [[ "${n:0:10}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [ "${n:10:${#stem}+10}" = "-gitbash-$stem-" ] || continue
  sha="${n:${#stem}+20}"
  [[ "$sha" =~ ^([0-9a-f]{7,40})\.txt$ ]] || continue
  named+=("$n")
  [[ "$PIN" != "${BASH_REMATCH[1]}"* ]] || at_pin+=("$n")
done
shopt -u nullglob
if [ "${#at_pin[@]}" -eq 0 ]; then
  [ "${#named[@]}" -eq 0 ] \
    || _fail "evidence/${named[${#named[@]}-1]//[[:cntrl:]]/?} is named for another head, not the pinned head ${PIN:0:7}"
  _fail "no evidence/<YYYY-MM-DD>-gitbash-$STEM-<sha>.txt is in the issue directory for the pinned head ${PIN:0:7}"
fi
tx="${at_pin[${#at_pin[@]}-1]}"
TX="evidence/${tx//[[:cntrl:]]/?}"

l1="" l2=""
{ IFS= read -r l1 || true; IFS= read -r l2 || true; } <"$issue_dir/evidence/$tx"
l1="${l1//$'\r'/}" l2="${l2//$'\r'/}"
if [[ ! "$l1" =~ $TX_SHA_RE ]]; then
  _show "$l1"
  _fail "$TX line 1 is not a full commit id: ${SHOWN:-(empty)}"
fi
sha="${BASH_REMATCH[2]}"
[ "$sha" = "$PIN" ] || _fail "$TX line 1 records head ${sha:0:7}, not the pinned head ${PIN:0:7}"
if [[ ! "$l2" =~ $TX_UNAME_RE ]]; then
  _show "$l2"
  _fail "$TX line 2 is not a Git Bash uname line (MINGW... or MSYS...): ${SHOWN:-(empty)}"
fi
printf 'transcript accepted: %s is at the pinned head %s\n' "$TX" "$PIN"
_exit 0
