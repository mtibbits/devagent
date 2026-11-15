#!/usr/bin/env bash
# scripts/claims-check.sh — #1122. The read-only claims half of the /devagent:preship
# preflight (commands/preship.md "Preflight (between 2 and 2a)"): it reads the issue's
# mr.md, recognises the claims a script can decide, compares each with git, the tree's
# `@test` blocks, a pytest collection or mr.md's own Evidence `suite:` line, and REPORTS
# the stale ones. It writes nothing: mr.md, HEAD, the index and the work tree are left
# byte-identical (tests/claims-check.bats pins that). The main session decides what to do
# with each report under the three correction rules in commands/preship.md; this script
# never passes or fails the step.
#
#   usage: claims-check.sh <project> <Issue-N>
#
# OPT-IN CONTEXT. Only the main-session preflight runs it, after preship-evidence.sh and
# before the head pin; the preship verifier never does, and nothing from it enters the
# dispatch prompt. It is also safe to run by hand (draftmr's dogfood run does).
#
# EXITS
#   0   no mismatch (NOT CHECKED lines may still print)
#   3   one or more MISMATCH lines printed
#   2   usage: argument count, any -* option, or ISSUE UNSTATED (no <Issue-N> and no
#       DEVAGENT_ACTIVE_ISSUE pin; the shared issue_dir slot is never a source)
#   1   could not run: no mr.md, no baseline_sha, an unresolvable tree or HEAD, any git
#       failure, any die. stderr then carries `claims-check: COULD NOT RUN — <reason>`
#       and stdout is empty.
#   11  quarantine (9 and 10 from the scope and trust guards)
# Exits 0 and 3 print, in mr.md line order, then one summary line:
#   mr.md:<L>: MISMATCH <kind>: <claim> — claimed <c>, found <f> (<basis>)
#   mr.md:<L>: NOT CHECKED <kind>: <claim> — <reason>
#   claims-check: checked <N> (bats-count <n>, pytest-count <n>, suite-total <n>,
#     commit-count <n>, files-count <n>, cited-commit <n>, signoff <n>); <M> mismatched;
#     <K> not checked
# "checked" counts the claims that were compared (equal or not); NOT CHECKED lines are
# counted in K only. <basis> is one of `at HEAD`, `at <sha12>`, `Evidence suite:`,
# `<base12>..HEAD`, `<ref>`.
#
# ORDER (evidence-stamp.sh's): project, scope guard, quarantine marker, EXIT trap,
# ISSUE UNSTATED, issue, issue dir, mr.md, tree, tree guard, then ONE `cd` into the
# tree: every git call (and the pytest resolve and collection) runs with cwd = the tree,
# as run-suite does.
#
# UNTRUSTED INPUT. mr.md is model-authored text. A path reaches git or pytest only as a
# key of the `git ls-tree -r -z --name-only HEAD` map; only a 7-40 hex token reaches
# git as a revision. Git calls that carry an mr.md token run with GIT_NO_LAZY_FETCH=1
# (git 2.44+ honours it). Stated blind spot: in a partial clone on git <= 2.43 a lazy
# fetch stays possible on such a call.
set -euo pipefail
export LC_ALL=C

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

: "${DEVAGENT_GIT:=git}"

usage="usage: claims-check.sh <project> <Issue-N>"
# _usage_exit <msg> - message and usage on stderr, exit 2 (the trap disarmed first).
_usage_exit() { trap - EXIT; printf 'claims-check: %s\n%s\n' "$1" "$usage" >&2; exit 2; }
# _cnr <reason> - could not run: exit 1 with the one stderr shape, stdout empty.
_cnr() { trap - EXIT; printf 'claims-check: COULD NOT RUN — %s\n' "$1" >&2; exit 1; }
# Any exit other than _finish, _usage_exit or _cnr (a lib die, an errexit) becomes 1.
_on_exit() {
  local rc=$?
  trap - EXIT
  printf 'claims-check: COULD NOT RUN — exited %s before the report was complete\n' "$rc" >&2
  exit 1
}

for _a in "$@"; do
  case "$_a" in -*) _usage_exit "unknown option '$_a'" ;; esac
done
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then _usage_exit "expected <project> <Issue-N>, got $# argument(s)"; fi

active_resolve_project_try "$1" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
[ -n "$project" ] || _cnr "project required"
config_is_project "$project" || _cnr "unknown project '$project'"
active_guard_scope claims-check
quarantine_guard_marker "claims-check" "$project" "${2:-}"
trap _on_exit EXIT

issue_arg="${2:-}"
if [ -z "$issue_arg" ] && [ -z "${DEVAGENT_ACTIVE_ISSUE:-}" ]; then
  _usage_exit "ISSUE UNSTATED — no issue was passed and DEVAGENT_ACTIVE_ISSUE is not set; pass it: claims-check.sh <project> <Issue-N> (#659: the shared issue_dir slot is never a source)"
fi
active_resolve_issue_src "$project" "$issue_arg"   # setter-globals; never $( … )
issue="$ACTIVE_RESOLVED_ISSUE"
issue_dir="$(issue_context_dir "$project" "$issue")" \
  || _cnr "could not derive the issue directory for $issue"
[ -d "$issue_dir" ] || _cnr "no issue directory for $issue: $issue_dir"
mr="$issue_dir/mr.md"
[ -f "$mr" ] || _cnr "no mr.md at $mr"
active_tree_resolve "$project" "$issue"   # setter-globals; never $( … )
active_guard_tree claims-check            # strictly after active_guard_scope (#571)
work_dir="$ACTIVE_TREE_DIR"
cd "$work_dir" || _cnr "cannot enter the tree $work_dir"

baseline_sha="$(state_ctx_get "$project" baseline_sha "$issue" 2>/dev/null || true)"
case "$baseline_sha" in null|'""') baseline_sha="" ;; esac
[ -n "$baseline_sha" ] || _cnr "no baseline_sha recorded for $issue"

_git() { "$DEVAGENT_GIT" "$@"; }
head_sha="$(_git rev-parse --verify --quiet 'HEAD^{commit}')" || _cnr "git rev-parse HEAD failed in $work_dir"

# The HEAD path map: the only door from an mr.md path to git or pytest.
# NUL-delimited, never C-quoted (Issue-590); the process substitution's status is read
# back with `wait $!`, so a failed ls-tree is never an empty map (Issue-314).
# BASE_N/BASE_P index the basenames, so a bare basename resolves only when unique.
declare -A TRACKED=() BASE_N=() BASE_P=()
mapfile -d '' -t _ls < <(_git ls-tree -r -z --name-only HEAD)
wait "$!" || _cnr "git ls-tree -r -z --name-only HEAD failed in $work_dir"
for _p in "${_ls[@]+"${_ls[@]}"}"; do
  TRACKED["$_p"]=1; _b="${_p##*/}"
  BASE_N["$_b"]=$(( ${BASE_N[$_b]:-0} + 1 )); BASE_P["$_b"]="$_p"
done
work_dir_p="$(pwd -P)"

# ---- the report -----------------------------------------------------------------------
KINDS=(bats-count pytest-count suite-total commit-count files-count cited-commit signoff)
declare -A CHECKED=()
for _k in "${KINDS[@]}"; do CHECKED["$_k"]=0; done
REPORTS=(); MISMATCHED=0; NOTCHECKED=0

# _finish - print the reports and the summary; exit 3 on any mismatch, else 0.
_finish() {
  local k n=0 parts=""
  for k in "${KINDS[@]}"; do
    n=$((n + CHECKED[$k])); parts+="${parts:+, }$k ${CHECKED[$k]}"
  done
  [ "${#REPORTS[@]}" -eq 0 ] || printf '%s\n' "${REPORTS[@]}"
  printf 'claims-check: checked %s (%s); %s mismatched; %s not checked\n' "$n" "$parts" "$MISMATCHED" "$NOTCHECKED"
  trap - EXIT
  [ "$MISMATCHED" -eq 0 ] || exit 3
  exit 0
}

# _mm <L> <kind> <claim> <claimed> <found> <basis> / _nc <L> <kind> <claim> <reason>
_mm() { REPORTS+=("mr.md:$1: MISMATCH $2: $3 — claimed $4, found $5 ($6)"); MISMATCHED=$((MISMATCHED + 1)); }
_nc() { REPORTS+=("mr.md:$1: NOT CHECKED $2: $3 — $4"); NOTCHECKED=$((NOTCHECKED + 1)); }
_counted() { CHECKED["$1"]=$((CHECKED[$1] + 1)); }
# _num <digits, commas allowed> - NUM: commas and leading zeros stripped. Counts stay
# strings: no bash arithmetic on an mr.md number (Issue-774).
_num() { local n="${1//,/}"; n="${n#"${n%%[!0]*}"}"; NUM="${n:-0}"; }

# ---- the claim grammar (imPlan "Claim grammar", revision 2) ----------------------------
# bash =~ (ERE) ONLY, never grep -E or sed -E: a variant run under another engine is not
# the measured grammar (Issue-106). `]` goes first in a bracket expression and a backslash
# is never a member; the multi-byte dashes and arrows are alternation members only (the
# script runs under LC_ALL=C, where they are byte sequences).
RE_P='-*[A-Za-z0-9_./+-]*[A-Za-z0-9_+-]\.[A-Za-z0-9]{1,8}'     # a path; a leading - only to refuse it
RE_BATS='\.bats$'
RE_PYTEST='^test_.+\.py$|_test\.py$'
RE_OTHER='(^|[._-])([Tt]ests?|[Ss]pec)([._-])|Test\.[A-Za-z]+$'
RE_CONN='^(`|:|[[:space:]]|\)|—|–|→|>|-)*((passes|passed|pass|has|now|ran|runs|with)[[:space:]]+)*'
RE_F1='^\(([0-9]{1,6}) tests?([^[:alnum:]]|$)'
RE_F2='^([0-9]{1,6})/([0-9]{1,6})([^0-9/%]|$)'
RE_F3='^([0-9]{1,6}) (tests?|passed|ok)([^[:alnum:]]|$)'
RE_F4='(^|[^[:alnum:]#,./-])([0-9]{1,6}) (tests?|cases) in[[:space:]]+$'
RE_JOINT='^([[:space:]]|,|&|[+])*(and)?([[:space:]]|,|&|[+])*$'
RE_EARLIER='(baseline|pre-branch|before|previously|earlier|was|were)'
RE_PARTIAL='(-k |--filter|subset|partial|only )'
RE_AT='(^|[^[:alnum:]])([Aa]t|@)[[:space:]]+`?([^`[:space:],;:)]+)`?'
RE_HEX='^[0-9a-f]{7,40}$'
RE_FENCE='^[[:space:]]*(```|~~~)'
RE_EMPH_PREV='^[[:space:]`(]$'
RE_EMPH_NEXT='^[[:space:][:punct:]]$'
RE_PATHCHARS='^[A-Za-z0-9._/+-]+$'
# The bats predicate, spelled ONCE; core-draft-mr's writer command quotes it (Task 12).
RE_TEST='^[[:blank:]]*@test[[:blank:]]'

# _p_spans <text> - P_S[]/P_E[]: start and end offsets of every P-shaped token, left to
# right. P has no context, so the first occurrence of a match is where it matched.
_p_spans() {
  local s="$1" off=0 m pre
  P_S=(); P_E=()
  while [[ "${s:off}" =~ $RE_P ]]; do
    m="${BASH_REMATCH[0]}"; pre="${s:off}"; pre="${pre%%"$m"*}"
    P_S+=("$((off + ${#pre}))"); P_E+=("$((off + ${#pre} + ${#m}))")
    off=$((off + ${#pre} + ${#m}))
  done
}

# _emph <text> - EMPH: ** and __ removed only as wrappers at a word edge (preceded by the
# start, whitespace, ` or (; or followed by the end, whitespace or punctuation), never
# inside a P-shaped token, so `tests/test_a__b.py` keeps its name (Issue-588).
_emph() {
  local s="$1" out="" i=0 n k=0 two prev next
  EMPH="$s"
  [[ "$s" == *'**'* || "$s" == *__* ]] || return 0
  _p_spans "$s"; n=${#s}
  while [ "$i" -lt "$n" ]; do
    if [ "$k" -lt "${#P_S[@]}" ] && [ "$i" -ge "${P_S[k]}" ]; then
      out+="${s:i:P_E[k]-i}"; i=${P_E[k]}; k=$((k + 1)); continue
    fi
    two="${s:i:2}"
    if [ "$two" = '**' ] || [ "$two" = '__' ]; then
      prev=""; [ "$i" -eq 0 ] || prev="${s:i-1:1}"
      next="${s:i+2:1}"
      if [ -z "$prev" ] || [[ "$prev" =~ $RE_EMPH_PREV ]] || [ -z "$next" ] || [[ "$next" =~ $RE_EMPH_NEXT ]]; then
        i=$((i + 2)); continue
      fi
    fi
    out+="${s:i:1}"; i=$((i + 1))
  done
  EMPH="$out"
}

# _class <path> - CLS by basename: bats | pytest | other (another framework) | "".
_class() {
  local b="${1##*/}"
  CLS=""
  if [[ "$b" =~ $RE_BATS ]]; then CLS=bats
  elif [[ "$b" =~ $RE_PYTEST ]]; then CLS=pytest
  elif [[ "$b" =~ $RE_OTHER ]]; then CLS=other
  fi
}

# _path <token> - RP: the tracked path an mr.md token names, else RP_WHY (a refusal).
# The ls-tree map is the only door: nothing else reaches git or pytest (imPlan
# "Untrusted input").
_path() {
  local p="$1" n
  RP=""; RP_WHY=""
  case "$p" in "$work_dir"/*) p="${p#"$work_dir"/}" ;; "$work_dir_p"/*) p="${p#"$work_dir_p"/}" ;; esac
  case "$p" in ./*) p="${p#./}" ;; esac
  case "$p" in
    *..*) RP_WHY="path refused (contains ..)"; return 0 ;;
    /*)   RP_WHY="path refused (absolute, outside the tree)"; return 0 ;;
    -*)   RP_WHY="path refused (leading -)"; return 0 ;;
  esac
  if [[ ! "$p" =~ $RE_PATHCHARS ]]; then RP_WHY="path refused (a character outside [A-Za-z0-9._/+-])"; return 0; fi
  if [ -n "${TRACKED[$p]+x}" ]; then RP="$p"; return 0; fi
  if [[ "$p" != */* ]]; then
    n="${BASE_N[$p]:-0}"
    if [ "$n" -eq 1 ]; then RP="${BASE_P[$p]}"; return 0; fi
    if [ "$n" -gt 1 ]; then RP_WHY="ambiguous basename ($n tracked files)"; return 0; fi
  fi
  RP_WHY="not tracked at HEAD"
}

# _gitt <args> - a git call that carries an mr.md token: GIT_NO_LAZY_FETCH=1 (header).
_gitt() { GIT_NO_LAZY_FETCH=1 "$DEVAGENT_GIT" "$@"; }

# _resolve <hex token> - RES: the one local commit it names, "" when none (rev-parse rc 1:
# unknown, a blob, a tree, or a prefix two commits share). Any other rc: could not run.
_resolve() {
  local out rc=0
  out="$(_gitt rev-parse --verify --quiet "$1^{commit}" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) RES="$out" ;;
    1) RES="" ;;
    *) _cnr "git rev-parse $1^{commit} failed (exit $rc) in $work_dir" ;;
  esac
}

# _at_commit <sentence> - AT_TOK: the sentence's at-commit token ("" when none). The
# phrases "the tip" and "the final SHA" mean HEAD and are matched first; else the first
# `at|At|@ <tok>` (A5), with one trailing . stripped (the class already stops at , ; : )).
_at_commit() {
  local s="$1"
  AT_TOK=""
  if [[ "$s" == *'the tip'* || "$s" == *'the final SHA'* ]]; then AT_TOK=HEAD; return 0; fi
  if [[ "$s" =~ $RE_AT ]]; then AT_TOK="${BASH_REMATCH[3]%.}"; fi
}

# _qual <text before the count> - QUAL: the earlier/partial NOT CHECKED reason, or "".
# Case-sensitive substrings, the path included (A4, as measured).
_qual() {
  QUAL=""
  if [[ "$1" =~ $RE_EARLIER ]]; then QUAL="an earlier run ('${BASH_REMATCH[1]}')"
  elif [[ "$1" =~ $RE_PARTIAL ]]; then QUAL="a partial run ('${BASH_REMATCH[1]}')"
  fi
}

declare -A BCACHE=()
# _bats_count <sha> <tracked path> - BC: its `@test` blocks at that commit.
_bats_count() {
  local key="$1:$2" content l n=0
  if [ -n "${BCACHE[$key]+x}" ]; then BC="${BCACHE[$key]}"; return 0; fi
  content="$(_gitt cat-file -p "$1:$2")" || _cnr "git cat-file -p ${1:0:12}:$2 failed in $work_dir"
  while IFS= read -r l; do
    if [[ "$l" =~ $RE_TEST ]]; then n=$((n + 1)); fi
  done <<<"$content"
  BCACHE[$key]=$n; BC=$n
}

# _bats_claim <L> <claim> <N> <path token> <text before the count> - one bats per-file
# count: qualifiers, then the path, then the commit, then the count.
_bats_claim() {
  local L="$1" claim="$2" path="$3" before="$4" n="$5" rev basis rc
  _qual "$before"
  if [ -n "$QUAL" ]; then _nc "$L" bats-count "$claim" "$QUAL"; return 0; fi
  rev="$head_sha"
  if [ -n "$AT_TOK" ] && [ "$AT_TOK" != HEAD ] && [[ ! "$AT_TOK" =~ $RE_HEX ]]; then
    _nc "$L" bats-count "$claim" "measured at $AT_TOK"; return 0
  fi
  _path "$path"
  if [ -z "$RP" ]; then _nc "$L" bats-count "$claim" "$RP_WHY"; return 0; fi
  if [ -n "$AT_TOK" ] && [ "$AT_TOK" != HEAD ]; then
    _resolve "$AT_TOK"
    if [ -z "$RES" ]; then _nc "$L" bats-count "$claim" "$AT_TOK resolves to no single local commit"; return 0; fi
    rev="$RES"
    if [ "$rev" != "$head_sha" ]; then
      rc=0; _gitt cat-file -e "$rev:$RP" 2>/dev/null || rc=$?
      case "$rc" in
        0) ;;
        1|128) _nc "$L" bats-count "$claim" "absent at ${rev:0:12}"; return 0 ;;
        *) _cnr "git cat-file -e ${rev:0:12}:$RP failed (exit $rc) in $work_dir" ;;
      esac
    fi
  fi
  basis="at HEAD"; [ "$rev" = "$head_sha" ] || basis="at ${rev:0:12}"
  _bats_count "$rev" "$RP"
  _num "$n"
  _counted bats-count
  [ "$NUM" = "$BC" ] || _mm "$L" bats-count "$claim" "$NUM" "$BC" "$basis"
}

# _scan_counts <L> <sentence> - the per-file count forms F1-F4 (imPlan "Per-file count").
# The window W runs from P's end (past its backtick) to the next P-shaped token, a `;`
# or the sentence end, at most 40 bytes, and must open with the connector.
_scan_counts() {
  local L="$1" s="$2" k np pstart pend p cls after lim w conn r n cpos cend cstart claim bd before between
  _p_spans "$s"
  local -a ps=("${P_S[@]+"${P_S[@]}"}") pe=("${P_E[@]+"${P_E[@]}"}")
  np=${#ps[@]}
  for ((k = 0; k < np; k++)); do
    pstart=${ps[k]}; pend=${pe[k]}; p="${s:pstart:pend-pstart}"
    _class "$p"; cls="$CLS"
    [ -n "$cls" ] || continue
    after=$pend; [ "${s:after:1}" != '`' ] || after=$((after + 1))
    # T3: P directly followed by ':' and a digit is a file:line citation (A10).
    if [[ "${s:pend:2}" =~ ^:[0-9] ]] || [[ "${s:after:2}" =~ ^:[0-9] ]]; then continue; fi
    lim=$((after + 40))
    if [ $((k + 1)) -lt "$np" ] && [ "${ps[k+1]}" -lt "$lim" ]; then lim=${ps[k+1]}; fi
    w="${s:after:lim-after}"; w="${w%%;*}"
    conn=""; if [[ "$w" =~ $RE_CONN ]]; then conn="${BASH_REMATCH[0]}"; fi
    r="${w:${#conn}}"; n=""; bd=""
    cstart=$pstart; [ "$pstart" -eq 0 ] || [ "${s:pstart-1:1}" != '`' ] || cstart=$((pstart - 1))
    if [[ "$r" =~ $RE_F1 ]]; then
      n="${BASH_REMATCH[1]}"; bd="${BASH_REMATCH[2]}"; cpos=$((after + ${#conn} + 1))
      cend=$((after + ${#conn} + ${#BASH_REMATCH[0]} - ${#bd})); [ "$bd" != ')' ] || cend=$((cend + 1))
    elif [[ "$r" =~ $RE_F2 ]]; then
      n="${BASH_REMATCH[2]}"; bd="${BASH_REMATCH[3]}"; cpos=$((after + ${#conn}))
      cend=$((after + ${#conn} + ${#BASH_REMATCH[0]} - ${#bd}))
    elif [[ "$r" =~ $RE_F3 ]]; then
      n="${BASH_REMATCH[1]}"; bd="${BASH_REMATCH[3]}"; cpos=$((after + ${#conn}))
      cend=$((after + ${#conn} + ${#BASH_REMATCH[0]} - ${#bd}))
    fi
    if [ -n "$n" ]; then
      claim="${s:cstart:cend-cstart}"
      # T9: P ending a test-path list (no count between) carries a joint count.
      if [ "$k" -gt 0 ]; then
        between="${s:pe[k-1]:pstart-pe[k-1]}"; between="${between//\`/}"
        _class "${s:ps[k-1]:pe[k-1]-ps[k-1]}"
        if [ -n "$CLS" ] && [[ "$between" =~ $RE_JOINT ]]; then
          _nc "$L" "$(_kind "$cls")" "$claim" "count for several files"; continue
        fi
      fi
    else
      # F4 reads the text before P's opening backtick (A8: T1's left boundary).
      before="${s:0:cstart}"
      [[ "$before" =~ $RE_F4 ]] || continue
      n="${BASH_REMATCH[2]}"; cpos=$(( ${#before} - ${#BASH_REMATCH[0]} + ${#BASH_REMATCH[1]} ))
      cend=$after; cstart=$cpos
      claim="${s:cstart:cend-cstart}"
    fi
    PF_SEEN=1
    case "$cls" in
      bats)   _bats_claim "$L" "$claim" "$p" "${s:0:cpos}" "$n" ;;
      pytest) : ;;   # Task 6
      other)  _nc "$L" test-count "$claim" "another framework" ;;
    esac
  done
}
# _kind <class> - the report kind of a per-file count.
_kind() { case "$1" in bats) echo bats-count ;; pytest) echo pytest-count ;; *) echo test-count ;; esac; }

# _scan_sentence <L> <sentence>
_scan_sentence() {
  PF_SEEN=0
  _at_commit "$2"
  _scan_counts "$1" "$2"
}

# ---- the scan ---------------------------------------------------------------------------
# Lines in mr.md order; one CR stripped. Skipped: the ## Evidence block (bounded as
# preship-evidence.sh bounds it, ignoring fences: A11), fenced blocks (a fence closes on
# the marker that opened it), and <!-- --> comments. A sentence is a split of one line on
# ". " and never spans lines (A2).
mapfile -t LINES < "$mr"
in_ev=false; fence=""; in_cmt=false
for ((li = 0; li < ${#LINES[@]}; li++)); do
  L=$((li + 1)); line="${LINES[li]%$'\r'}"
  if [[ "$line" == '## Evidence'* ]]; then in_ev=true; continue; fi
  if [[ "$line" == '## '* ]]; then in_ev=false; fi
  if $in_ev; then continue; fi
  if [ -n "$fence" ]; then
    if [[ "$line" =~ $RE_FENCE ]] && [ "${BASH_REMATCH[1]}" = "$fence" ]; then fence=""; fi
    continue
  fi
  if [[ "$line" =~ $RE_FENCE ]]; then fence="${BASH_REMATCH[1]}"; continue; fi
  text="$line"
  if $in_cmt; then
    if [[ "$text" == *'-->'* ]]; then text="${text#*-->}"; in_cmt=false; else continue; fi
  fi
  while [[ "$text" == *'<!--'* ]]; do
    _pre="${text%%<!--*}"; _post="${text#*<!--}"
    if [[ "$_post" == *'-->'* ]]; then text="$_pre${_post#*-->}"; else text="$_pre"; in_cmt=true; break; fi
  done
  _emph "$text"; rest="$EMPH"
  while :; do
    case "$rest" in
      *'. '*) sent="${rest%%. *}"; rest="${rest#*. }" ;;
      *) sent="$rest"; rest="" ;;
    esac
    _scan_sentence "$L" "$sent"
    [ -n "$rest" ] || break
  done
done

_finish
