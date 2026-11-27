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
#           Each shard job runs `gitbash-tagged.sh select tests`, which globs tests/*.bats: a
#           subdirectory, another directory or a dot-file is never run.
#       <test-file> does not exist at <pin7>
#       <test-file> carries no gitbash tag line at <pin7>
#           The file as the pinned commit holds it, alone in a temporary directory,
#           must be listed by scripts/ci/gitbash-tagged.sh select, the plugin's copy of
#           the job's selector. A tag line the selector calls malformed is none.
#       no test named '<test-name>' in <test-file> at <pin7>
#       test '<test-name>' in <test-file> at <pin7> is named more than once
#           A test is a line `@test "<n>" {` or `@test '<n>' {`, trailing blanks aside.
#           <test-name> is <n> as the source spells it or, for a double-quoted <n>, as
#           bats displays it (`C:\\x` in the source is `C:\x`). Its body runs to the
#           next line that is exactly `}`. A test written on one line is not read.
#       <test-file>:<line>: Git Bash skip guard in '<test-name>': <the line, at most 120 characters>
#           A line of the body skips on the job's host, or calls a function of the
#           file that does. The predicate, and the misses it is known to have, are
#           described at its code.
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
# The question for a `skip` is its direction: does it run on the job's host? That host
# is Git Bash on the Windows runner, and a guard is read against what its subject holds
# there (the HOST_* values below): `uname -s` is MINGW64_NT-..., `uname -o` is Msys,
# OSTYPE is msys. A test for another flavour (MSYS*, CYGWIN*, cygwin) is false there.
#
# A line is read as code only: quoted text and comments are masked first (_mask). A
# `skip` command word (not part of a longer word, followed by a blank, `;` or the end
# of the line) TRIPS when
#   - the code before it on its line names Git Bash (GB_TOKEN_RE, any case), unless
#     that whole code is one of the forms below and the skip does not run on the host; or
#   - it stands under a case arm whose pattern names a Git Bash value (mingw, msys or
#     cygwin, any case: every flavour, wider than the forms below on purpose) that an
#     earlier line opened and that is still open. The arm closes at its own `;;` or
#     its statement's `esac`: a case nested in it does not close it, and once it ends
#     in `;&` or `;;&` it stays open to the `esac`.
# The forms, <T> being a test whose truth on the host is known:
#   <T> || skip          no trip when <T> is true there    (also `|| {`)
#   <T> && skip          no trip when <T> is false there   (also `&& {`)
#   if <T>; then skip    no trip when <T> is false there
#   case <subject> in <patterns>) ... ;; <patterns>) ... skip
#                        one case statement, still open, none nested in it, no `;&`
#                        or `;;&`: no trip when the host's value matches an earlier
#                        arm, or does not match the arm the skip stands in
# <T> is `is_git_bash` (true), `[ a = b ]`, `[[ a == b ]]`, `[[ a =~ b ]]`, the same
# with `!=`, and any of them after `!` or with `!` first inside the brackets. One side
# must be a subject: "$(uname -s)", "$(uname)", "$(uname -o)" or "$OSTYPE", spelled so.
# The other must be a literal, and the comparison is made as bash makes it: `[ ]`
# compares strings (so `[ "$(uname -s)" = MINGW* ]` is never true), `[[ ]]` matches an
# unquoted pattern or regular expression.
# Everything else that names Git Bash before a skip trips, whichever way it points: a
# guard this cannot read fails the check rather than pass it. So a variable that holds
# uname, "$MSYSTEM", `test`, a compound test and `if ...; then :; else skip` all trip.
# One level of indirection: a call to a function of the same file one of whose own
# lines trips is a trip too. A function is `name() {` or `function name {`, at any
# indent, its brace on that line or alone on the next, its body on the lines up to its
# closing brace at the same indent (alone, or with a redirection, `;`, `|`, `&` or a
# comment after it), or on its one line. Every line of the file is read for a
# definition, inside another function's body too; a body whose closing brace is not
# found is read to the end of the file.
#
# That is all that is read: each line of the named test's body by itself, up to the
# first `}` at column 0; the Git Bash case arm that may stand open over it; and, where
# a body line names one, the lines of a function this file defines.
# KNOWN MISSES follow from that. A test with one of these is skipped on Git Bash and
# deferred all the same; tests/fixtures/preship-deferred/ holds a test for each, pinned
# as a miss (misses.bats, misses-word.bats, and the two `miss:` tests of guards.bats).
#   - a guard spread over lines: `if is_git_bash; then` / `skip`; a line continued
#     with a backslash; an early return (`is_git_bash || return 0`, then `skip`); a
#     case over several lines whose skipping arm does not name Git Bash;
#   - a helper that calls a helper, and a helper kept in another file;
#   - a helper this does not register: a subshell body `name() (`, a hyphenated name,
#     a blank line between `name()` and its `{`, a definition that does not start its
#     line (`_a() { :; }; name() {`);
#   - a helper whose body ends early: a line at its indent that closes a brace group
#     with a redirection (`} >&2`), or a heredoc line `}`, before its guard;
#   - a Git Bash arm this does not open: an extglob pattern (`@(MINGW|MSYS)*)`) on its
#     own line;
#   - a skip in setup();
#   - `is_git_bash` taken at its word: it is read as true on the job's host, whatever
#     the file, or a file it loads, defines it to be;
#   - a skip on a line that does not name Git Bash and is under no open Git Bash arm
#     (`[ -n "${WINDIR:-}" ] && skip`, a bare `skip`);
#   - a line after the first `}` at column 0 inside the test (a heredoc's): the body
#     is read up to there.
# The job itself fails a file whose every test skips, and a skip with no reason.

GB_TOKEN_RE='is_git_bash|uname|ostype|mingw|msys|cygwin'    # read against lower case
WORD_END_RE='[[:alnum:]_-]$'
WORD_AFTER_RE='^([^[:alnum:]_-]|$)'
SKIP_AFTER_RE='^([[:space:];]|$)'
SAFE_OP_RE='^(.*[^[:space:]])[[:space:]]*(\|\||&&)[[:space:]]*\{?$'
SAFE_IF_RE='^if[[:space:]]+(.*[^[:space:]])[[:space:]]*;[[:space:]]*then$'
CASE_HEAD_RE='^case[[:space:]]+([^[:space:]]+)[[:space:]]+in[[:space:]]+(.*)$'
ARM_RE='^([[:space:]]*\(?)([^()]*)\)(.*)$'
ARM_OPEN_RE='^[[:space:]]*\(?[^()]*(mingw|msys|cygwin)[^()]*\)'

# The job's host. Two builds of the one Windows line: a literal that names a build is
# true on one and not the other, so it is not read.
HOST_UNAME_S=('MINGW64_NT-10.0-26100' 'MINGW64_NT-10.0-20348')
HOST_UNAME_O=(Msys)
HOST_OSTYPE=(msys)
# shellcheck disable=SC2016  # regular expressions: nothing here is meant to expand
SUBJ_UNAME_RE='^"?(\$\(|`)[[:space:]]*uname([[:space:]]+-([so]))?[[:space:]]*(\)|`)"?$'
SUBJ_OSTYPE_RE='^"?\$\{?OSTYPE\}?"?$'
# shellcheck disable=SC2016
EXPANSION_RE='\$[A-Za-z_0-9{(@*#?!$-]|`|[\]'

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

# _word_at <text> <word> <after-re>: sets WORD_AT=( index ... ): where <word> starts
# as a word of <text>, what follows it matching <after-re>.
_word_at() {
  local t="$1" w="$2" s="$1" off=0 before
  WORD_AT=()
  while [[ "$s" == *"$w"* ]]; do
    before="${s%%"$w"*}"
    off=$((off + ${#before}))
    s="${s:${#before}+${#w}}"
    if [[ ! "${t:0:off}" =~ $WORD_END_RE ]] && [[ "$s" =~ $3 ]]; then WORD_AT+=("$off"); fi
    off=$((off + ${#w}))
  done
}

# _word_count <text> <word>: sets WORDS to how often <word> stands in <text> as a word.
_word_count() { _word_at "$1" "$2" "$WORD_AFTER_RE"; WORDS=${#WORD_AT[@]}; }

# _split <maskw> <raw>: sets WM to the blank-separated words of <maskw> and WR to the
# same spans of <raw>. The two are character for character, and a quoted word of
# <maskw> holds no blank, so WR has each word as the source spells it.
_split() {
  local m="$1" r="$2" n=${#1} i=0 j
  WM=(); WR=()
  while ((i < n)); do
    while ((i < n)) && [[ "${m:i:1}" == [[:space:]] ]]; do i=$((i + 1)); done
    ((i < n)) || break
    j=$i
    while ((j < n)) && [[ "${m:j:1}" != [[:space:]] ]]; do j=$((j + 1)); done
    WM+=("${m:i:j-i}"); WR+=("${r:i:j-i}")
    i=$j
  done
}

# _host_models <word>: rc 0 when <word>, as the source spells it, is a subject whose
# value on the job's host is known. MODELS is then those values.
_host_models() {
  MODELS=()
  if [[ "$1" =~ $SUBJ_UNAME_RE ]]; then
    if [ "${BASH_REMATCH[3]}" = o ]; then MODELS=("${HOST_UNAME_O[@]}"); else MODELS=("${HOST_UNAME_S[@]}"); fi
  elif [[ "$1" =~ $SUBJ_OSTYPE_RE ]]; then
    MODELS=("${HOST_OSTYPE[@]}")
  else
    return 1
  fi
}

# _literal <word>: rc 0 when <word>, as the source spells it, is a literal: no
# expansion, no backslash, quoted as a whole or not at all. LIT is its text; LITQ is 1
# when it was quoted, so that a pattern character in it is plain text.
_literal() {
  local w="$1"
  LIT=""; LITQ=0
  [[ ! "$w" =~ $EXPANSION_RE ]] || return 1
  case "$w" in
    \"*\"|\'*\') w="${w:1:${#w}-2}"; LITQ=1 ;;
  esac
  [[ "$w" != *[\"\']* ]] || return 1
  LIT="$w"
}

# _regex_matches <value> <regular expression>: bash's own answer, 2 for an expression
# it cannot compile.
_regex_matches() { [[ "$1" =~ $2 ]] 2>/dev/null; }

# _host_truth <[ or [[> <left> <operator> <right>, the words as the source spells them:
# sets HT to 1 when the comparison is true on the job's host, 0 when it is false there,
# and leaves it empty when that cannot be told: neither side is a known subject, the
# other is not a literal, or the answer differs between the host's builds.
_host_truth() {
  local kind="$1" a="$2" op="$3" b="$4" rev=0 v t rc first=""
  HT=""
  if _host_models "$a" && _literal "$b"; then :
  elif [ "$op" != '=~' ] && _host_models "$b" && _literal "$a"; then rev=1
  else return 0
  fi
  for v in "${MODELS[@]}"; do
    t=0
    case "$kind$op" in
      '[='|'[=='|'[!=')
        [ "$v" != "$LIT" ] || t=1 ;;
      '[[='|'[[=='|'[[!=')
        if [ "$LITQ" -eq 1 ] || [ "$rev" -eq 1 ]; then
          [ "$v" != "$LIT" ] || t=1
        else
          # shellcheck disable=SC2053  # the literal is the guard's own pattern
          [[ "$v" != $LIT ]] || t=1
        fi ;;
      '[[=~')
        [ "$LITQ" -eq 0 ] || return 0
        rc=0
        _regex_matches "$v" "$LIT" || rc=$?
        case "$rc" in 0) t=1 ;; 1) ;; *) return 0 ;; esac ;;       # 2: not a regular expression
      *) return 0 ;;
    esac
    [ -n "$first" ] || first="$t"
    [ "$t" = "$first" ] || return 0
  done
  [ "$op" != '!=' ] || first=$((1 - first))
  HT="$first"
}

# _gb_polarity <maskw test> <raw test>: one test command, the code and the same span
# of the source. Sets POL to `is` (true on the job's host), `isnot` (false there) or
# empty (not a test this reads).
_gb_polarity() {
  local neg=0 kind n
  POL=""
  _split "$1" "$2"
  n=${#WM[@]}
  ((n > 0)) || return 0
  if [ "${WM[0]}" = '!' ]; then neg=1; WM=("${WM[@]:1}"); WR=("${WR[@]:1}"); n=$((n - 1)); fi
  if ((n == 1)) && [ "${WM[0]}" = is_git_bash ]; then
    HT=1
  else
    ((n >= 5)) || return 0
    case "${WM[0]} ${WM[n-1]}" in
      '[[ ]]') kind='[[' ;;
      '[ ]')   kind='[' ;;
      *) return 0 ;;
    esac
    WM=("${WM[@]:1:n-2}"); WR=("${WR[@]:1:n-2}"); n=$((n - 2))
    if [ "${WM[0]}" = '!' ]; then neg=$((1 - neg)); WM=("${WM[@]:1}"); WR=("${WR[@]:1}"); n=$((n - 1)); fi
    ((n == 3)) || return 0
    _host_truth "$kind" "${WR[0]}" "${WM[1]}" "${WR[2]}"
    [ -n "$HT" ] || return 0
  fi
  if [ "$neg" -eq 1 ]; then HT=$((1 - HT)); fi
  if [ "$HT" -eq 1 ]; then POL=is; else POL=isnot; fi
}

# _plist_matches <value> <pattern list>: rc 0 when <value> matches one of the `|`
# alternatives of a case arm's pattern list.
_plist_matches() {
  local v="$1" rest="$2" alt
  while :; do
    alt="${rest%%|*}"
    alt="${alt#"${alt%%[![:space:]]*}"}"
    alt="${alt%"${alt##*[![:space:]]}"}"
    # shellcheck disable=SC2053  # the alternative is the guard's own pattern
    [[ "$v" != $alt ]] || return 0
    [[ "$rest" == *"|"* ]] || return 1
    rest="${rest#*|}"
  done
}

# _safe_case <maskw> <raw>: the code before a skip, trimmed, and the same span of the
# source. rc 0 when it is one case statement, still open, with no `;&` or `;;&` and no
# case nested in it, over a subject whose value on the job's host is known, and the
# host does not run the arm the skip stands in: its value matches an earlier arm, or
# does not match this one.
_safe_case() {
  local p="$1" r="$2" tmp lead subj am ar before plist v i last hit
  local -a sm=() sr=() pl=()
  [[ "$p" != *';&'* ]] || return 1
  _word_count "$p" 'case'
  [ "$WORDS" -eq 1 ] || return 1
  _word_count "$p" 'esac'
  [ "$WORDS" -eq 0 ] || return 1
  [[ "$p" =~ $CASE_HEAD_RE ]] || return 1
  subj="${BASH_REMATCH[1]}"; am="${BASH_REMATCH[2]}"
  tmp="${p#case}"; lead="${tmp%%[![:space:]]*}"
  _host_models "${r:4+${#lead}:${#subj}}" || return 1
  ar="${r:${#r}-${#am}}"
  while [[ "$am" == *';;'* ]]; do
    before="${am%%;;*}"
    sm+=("$before"); sr+=("${ar:0:${#before}}")
    am="${am:${#before}+2}"; ar="${ar:${#before}+2}"
  done
  sm+=("$am"); sr+=("$ar")
  last=$(( ${#sm[@]} - 1 ))
  for i in "${!sm[@]}"; do
    [[ "${sm[i]}" =~ $ARM_RE ]] || return 1
    lead="${BASH_REMATCH[1]}"
    plist="${sr[i]:${#lead}:${#BASH_REMATCH[2]}}"
    [[ ! "$plist" =~ $EXPANSION_RE ]] || return 1
    [[ "$plist" != *[\"\']* ]] || return 1
    pl+=("$plist")
  done
  for v in "${MODELS[@]}"; do
    hit=-1
    for i in "${!pl[@]}"; do
      if _plist_matches "$v" "${pl[i]}"; then hit="$i"; break; fi
    done
    [ "$hit" -ne "$last" ] || return 1
  done
  return 0
}

# _safe_form <maskw> <raw>: the code before a skip and the same span of the source.
# rc 0 when that code is one of the forms this reads and the skip does not run on the
# job's host.
_safe_form() {
  local p="$1" r="$2" lead trail cond op tmp
  lead="${p%%[![:space:]]*}"
  p="${p:${#lead}}"; r="${r:${#lead}}"
  trail="${p##*[![:space:]]}"
  p="${p:0:${#p}-${#trail}}"; r="${r:0:${#p}}"
  if [[ "$p" =~ $SAFE_OP_RE ]]; then
    cond="${BASH_REMATCH[1]}"; op="${BASH_REMATCH[2]}"
    _gb_polarity "$cond" "${r:0:${#cond}}"
    [[ "$op" == '||' && "$POL" == is ]] || [[ "$op" == '&&' && "$POL" == isnot ]]
    return
  fi
  if [[ "$p" =~ $SAFE_IF_RE ]]; then
    cond="${BASH_REMATCH[1]}"
    tmp="${p#if}"; lead="${tmp%%[![:space:]]*}"
    _gb_polarity "$cond" "${r:2+${#lead}:${#cond}}"
    [ "$POL" = isnot ]
    return
  fi
  _safe_case "$p" "$r"
}

# _arm_reset: before the first line of a body.
_arm_reset() { ARM_GB=0; ARM_STICKY=0; ARM_DEPTH=0; CASE_DEPTH=0; }

# _arm_track <MASK> <MASKW>: a line's two masks, lower case. Follows the case
# statements of a body. ARM_GB is 1 while a case arm whose pattern names a Git Bash
# value is open. Only its own statement closes it (CASE_DEPTH against ARM_DEPTH), at
# `;;` or `esac`; after `;&` or `;;&` (ARM_STICKY) the arms that follow can run on Git
# Bash too, so only `esac` does. Keywords and terminators are read from MASK, where no
# quoted text can pass for one; a pattern is read from MASKW, which keeps its text.
_arm_track() {
  local rest="$1" restw="$2" seg segw term before
  while :; do
    before="${rest%%;[;&]*}"
    if [ "$before" = "$rest" ]; then
      seg="$rest"; segw="$restw"; term=""; rest=""
    else
      seg="$before"; segw="${restw:0:${#before}}"; term="${rest:${#before}:2}"
      rest="${rest:${#before}+2}"; restw="${restw:${#before}+2}"
      if [ "$term" = ';;' ] && [ "${rest:0:1}" = '&' ]; then term=';;&'; rest="${rest:1}"; restw="${restw:1}"; fi
    fi
    _word_count "$seg" 'case'
    CASE_DEPTH=$((CASE_DEPTH + WORDS))
    if [ "$ARM_GB" -eq 0 ] && [ "$CASE_DEPTH" -gt 0 ] && [[ "$segw" =~ $ARM_OPEN_RE ]]; then
      ARM_GB=1; ARM_STICKY=0; ARM_DEPTH="$CASE_DEPTH"
    fi
    _word_count "$seg" 'esac'
    while ((WORDS > 0)); do
      if [ "$CASE_DEPTH" -le "$ARM_DEPTH" ]; then ARM_GB=0; ARM_STICKY=0; fi
      if ((CASE_DEPTH > 0)); then CASE_DEPTH=$((CASE_DEPTH - 1)); fi
      WORDS=$((WORDS - 1))
    done
    case "$term" in
      '')   break ;;
      ';;') if [ "$ARM_STICKY" -eq 0 ] && [ "$CASE_DEPTH" -le "$ARM_DEPTH" ]; then ARM_GB=0; fi ;;
      *)    if [ "$ARM_GB" -eq 1 ] && [ "$CASE_DEPTH" -le "$ARM_DEPTH" ]; then ARM_STICKY=1; fi ;;
    esac
  done
}

# _line_trips <line>: rc 0 when <line> holds a skip that can run on the job's host. It
# follows the open Git Bash arm across the lines of one body: _arm_reset comes first.
_line_trips() {
  local line="$1" at pre hit=1
  [[ "$line" == *skip* || "$line" == *")"* || "$line" == *";;"* || "$line" == *";&"* \
     || "$line" == *case* || "$line" == *esac* ]] || return 1
  _mask "$line"
  if [[ "$MASK" == *skip* ]]; then
    _word_at "$MASK" skip "$SKIP_AFTER_RE"     # each skip command word; the loop's list is
    for at in ${WORD_AT[@]+"${WORD_AT[@]}"}; do   # expanded once, so _safe_form may reuse WORD_AT
      pre="${MASKW:0:at}"
      if [[ "${pre,,}" =~ $GB_TOKEN_RE ]]; then
        _safe_form "$pre" "${line:0:at}" || { hit=0; break; }
      elif [ "$ARM_GB" -eq 1 ]; then
        hit=0; break
      fi
    done
  fi
  _arm_track "${MASK,,}" "${MASKW,,}"
  return "$hit"
}

# _body_end <first>: sets BODY_END to the index of the next line of LINES, from
# <first>, that is exactly `}` (trailing blanks aside), or to the line count. A test's
# body ends there.
_body_end() {
  local j l
  for ((j = $1; j < ${#LINES[@]}; j++)); do
    l="${LINES[j]}"
    [ "${l%"${l##*[![:space:]]}"}" != "}" ] || break
  done
  BODY_END="$j"
}

FN_RE='^([[:blank:]]*)([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*\(\)[[:blank:]]*(.*)$'
FN_KW_RE='^([[:blank:]]*)function[[:blank:]]+([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*(\(\))?[[:blank:]]*(.*)$'
# What may follow a function's closing brace on its line: nothing, `;`, a redirection,
# `|`, `&` or `)`. (A comment is gone before this is asked: the line is masked.)
CLOSER_RE='^\}[[:blank:]]*($|[;><|&)]|[0-9]+[<>])'

# _helper_end <first> <indent>: sets BODY_END to the index of the next line of LINES,
# from <first>, that closes a function defined at <indent>: <indent>`}`, alone or with
# what CLOSER_RE allows after it. The line count when there is none: the body is then
# read to the end of the file, which can only add trips.
_helper_end() {
  local j l indent="$2"
  for ((j = $1; j < ${#LINES[@]}; j++)); do
    l="${LINES[j]}"
    [[ "$l" == "$indent}"* ]] || continue
    _mask "$l"
    [[ ! "${MASK:${#indent}}" =~ $CLOSER_RE ]] || break
  done
  BODY_END="$j"
}

# _helpers: fills SKIPPERS (name -> 1) with the functions of LINES one of whose own
# lines trips. A function is `name() {` or `function name {` at any indent, the brace
# on that line or alone on the next, its body on the lines up to its closing brace at
# the same indent (_helper_end), or on its one line: the braces of that line balance
# and what follows the last one is what may follow a closing brace.
# EVERY line is read for a definition, the lines of another function's body too: a
# function defined inside a function is found, and a body whose end is not where
# _helper_end looks hides no definition after it.
_helpers() {
  local j k line indent fn rest first open close opens closes
  SKIPPERS=()
  for ((j = 0; j < ${#LINES[@]}; j++)); do
    line="${LINES[j]}"
    [[ "$line" == *"()"* || "$line" == *function* ]] || continue
    _mask "$line"
    if [[ "$MASK" =~ $FN_KW_RE ]]; then indent="${BASH_REMATCH[1]}"; fn="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[4]}"
    elif [[ "$MASK" =~ $FN_RE ]]; then indent="${BASH_REMATCH[1]}"; fn="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    else continue
    fi
    first=$((j + 1))
    if [[ ! "$rest" =~ [^[:space:]] ]]; then
      # the brace alone on the next line
      ((first < ${#LINES[@]})) || continue
      line="${LINES[first]}"
      _mask "$line"
      rest="${MASK#"${MASK%%[![:space:]]*}"}"
      first=$((first + 1))
    fi
    [[ "$rest" == "{"* ]] || continue
    [ -z "${SKIPPERS[$fn]:-}" ] || continue      # a second definition of a known skipper
    _arm_reset
    open="${MASK%%\{*}"                          # the code up to the opening brace
    opens="${rest//[^\{]/}"; closes="${rest//[^\}]/}"
    if [ "${#opens}" -eq "${#closes}" ] && [[ "}${MASK##*\}}" =~ $CLOSER_RE ]]; then
      # written on one line: its body is the text between that brace and the last `}`
      close="${MASK%\}*}"
      ! _line_trips "${line:${#open}+1:${#close}-${#open}-1}" || SKIPPERS[$fn]=1
      continue
    fi
    if _line_trips "${line:${#open}+1}"; then SKIPPERS[$fn]=1; continue; fi
    _helper_end "$first" "$indent"
    for ((k = first; k < BODY_END; k++)); do
      if _line_trips "${LINES[k]}"; then SKIPPERS[$fn]=1; break; fi
    done
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
  local path="$1" F="${1//[[:cntrl:]]/?}" top rc=0
  _selfcert_top "$TREE"
  top="$_SELFCERT_TOP"
  _selfcert_git -C "$top" rev-parse --verify --quiet "${PIN}^{commit}" >/dev/null 2>&1 \
    || _cnr "${PIN:0:7} is not a commit in $TREE"
  _selfcert_blob "$top" "$PIN" "$path" || _cnr "$F at ${PIN:0:7} cannot be read in $TREE ($_SELFCERT_ERR)"
  [ -n "$_SELFCERT_OID" ] || _fail "$F does not exist at ${PIN:0:7}"
  TMP="$(mktemp -d)"
  mkdir "$TMP/sel"
  BLOB="$TMP/sel/${path##*/}"
  _selfcert_git -C "$top" cat-file blob "$_SELFCERT_OID" 2>/dev/null | tr -d '\r' >"$BLOB" || rc=$?
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
    *) _fail "test '$N' in $F at ${PIN:0:7} is named more than once" ;;
  esac

  # 4. no line of its body, and no helper it calls, skips on Git Bash
  declare -A SKIPPERS=()
  _helpers
  first=$((hits[0] + 1))
  _body_end "$first"
  _arm_reset
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
# compared as text. `named` is the last that fits the form; `tx` the last that also
# names the pinned head. The glob is sorted in the C locale, so the last is the
# lexicographically last name.
named="" tx=""
shopt -s nullglob
for p in "$issue_dir"/evidence/*; do
  n="${p##*/}"
  [ -f "$p" ] || continue
  [[ "${n:0:10}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [ "${n:10:${#stem}+10}" = "-gitbash-$stem-" ] || continue
  sha="${n:${#stem}+20}"
  [[ "$sha" =~ ^([0-9a-f]{7,40})\.txt$ ]] || continue
  named="$n"
  [[ "$PIN" != "${BASH_REMATCH[1]}"* ]] || tx="$n"
done
shopt -u nullglob
if [ -z "$tx" ]; then
  [ -z "$named" ] \
    || _fail "evidence/${named//[[:cntrl:]]/?} is named for another head, not the pinned head ${PIN:0:7}"
  _fail "no evidence/<YYYY-MM-DD>-gitbash-$STEM-<sha>.txt is in the issue directory for the pinned head ${PIN:0:7}"
fi
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
