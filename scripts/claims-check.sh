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
# DEVAGENT_COLLECT_TIMEOUT (seconds, a positive integer, default 30) bounds each pytest
# collection; an invalid value is COULD NOT RUN. Like run-suite's one-run knobs it is
# scrubbed from every suite child (SUITE_CHILD_UNSET).
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
# counted in K only. <basis> is one of `at HEAD`, `at <sha12>`, `collected at HEAD`
# (a pytest count, compared with the collected ids), `Evidence suite:`,
# `<base12>..HEAD`, `<ref>`. A pytest pass count (pass, passed, ok, …) below the
# collected count adds "; a pass count below it can be true when tests skip or xfail"
# to `collected at HEAD`: a prompt to look, since skips are not collected apart.
# A NOT CHECKED line may also carry the kind `test-count` (a count for a framework
# other than bats and pytest); it is never compared and has no summary count.
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
#
# LABELS. S1-S3, F1-F4, C1, C2, D1, D2, H1 and H2 are the recognised forms (the RE_*
# below); T1-T9, A1-A12, U6 and "decision N" cite the rows of Issue-1122's imPlan.md.
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
# shellcheck source=lib/platform.sh
. "$DEVAGENT_ROOT/scripts/lib/platform.sh"
# shellcheck source=lib/evidence.sh
. "$DEVAGENT_ROOT/scripts/lib/evidence.sh"
# shellcheck source=lib/python-interp.sh
. "$DEVAGENT_ROOT/scripts/lib/python-interp.sh"
# shellcheck source=lib/upstream.sh
. "$DEVAGENT_ROOT/scripts/lib/upstream.sh"
# shellcheck source=lib/baseline.sh
. "$DEVAGENT_ROOT/scripts/lib/baseline.sh"

: "${DEVAGENT_GIT:=git}"

usage="usage: claims-check.sh <project> <Issue-N>"
# _usage_exit <msg> - message and usage on stderr, exit 2 (the trap disarmed first).
_usage_exit() { trap - EXIT; printf 'claims-check: %s\n%s\n' "$1" "$usage" >&2; exit 2; }
# _cnr <reason> - could not run: exit 1 with the one stderr shape, stdout empty.
_cnr() { trap - EXIT; printf 'claims-check: COULD NOT RUN — %s\n' "$1" >&2; exit 1; }
# Any exit other than _finish, _usage_exit or _cnr (a lib die, an errexit) becomes 1.
# shellcheck disable=SC2317  # invoked by the EXIT trap
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
# The bound on each pytest collection (seconds), validated before anything runs, as
# run-suite validates DEVAGENT_FETCH_TIMEOUT. Scrubbed from the collection child.
collect_timeout="${DEVAGENT_COLLECT_TIMEOUT:-30}"
[[ "$collect_timeout" =~ ^[1-9][0-9]*$ ]] \
  || _cnr "DEVAGENT_COLLECT_TIMEOUT must be a positive integer (seconds), got '$collect_timeout' — it bounds each pytest collection; unset it for the default, 30"

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
# A per-file count in a sentence that also counts skips or xfails is a pass count, not the
# file's size: NOT CHECKED, never compared with @test blocks or collected ids.
RE_SKIPS='(skip|xfail|xpass|deselect)'
# A pass count, as against a size: the claim names passing.
RE_PASSW='(^|[^[:alnum:]])(pass|passes|passed|passing|ok|green)([^[:alnum:]]|$)'
# shellcheck disable=SC2016  # the backticks are literal markdown, not a command
RE_AT='(^|[^[:alnum:]])([Aa]t|@)[[:space:]]+`?([^`[:space:],;:)]+)`?'
RE_HEX='^[0-9a-f]{7,40}$'
RE_FENCE='^[[:space:]]*(```|~~~)'
RE_EMPH_PREV='^[[:space:]`(]$'
RE_EMPH_NEXT='^[[:space:][:punct:]]$'
RE_PATHCHARS='^[A-Za-z0-9._/+-]+$'
RE_COLLECTED='^([0-9]+) tests? collected'
# Suite totals. NUM (T1) is the first number of S1-S3, C1, C2 and D1: commas allowed
# inside, never after #, comma, dot, slash or dash.
RE_NUMG='([0-9]|[0-9][0-9,]{0,7}[0-9])'
RE_NUM="(^|[^[:alnum:]#,./-])${RE_NUMG}"
RE_S1="${RE_NUM}/${RE_NUMG} bats"
RE_S2="(^|[^[:alnum:]#,./=-])${RE_NUMG} pytest([^[:alnum:]_]|\$)"
RE_S3='(full|whole|entire)( bats| pytest)? suites?'                 # on the lowercased sentence
RE_S3N="${RE_NUM}( tests?)? (passed|pass)"
RE_AB="${RE_NUM}/${RE_NUMG}"
RE_T2='^[[:space:]]+(tests?|cases?)([^[:alnum:]]|$)'
RE_NOUN='^[[:space:]]+([A-Za-z]+)'
S2_WORDS=' passed pass passes passing green ok at in on and plus with '
# shellcheck disable=SC2016  # the backticks are literal markdown, not a command
RE_AFTER='(^|[^[:alnum:]])[Aa]fter([[:space:]]+[A-Za-z0-9_'"'"'-]+){1,4}[[:space:]]*\([[:space:]]*`?([0-9a-f]{7,40})`?[[:space:]]*\)'
RE_EVLINE='^suite:[[:space:]]*(.*)$'
# Commit and file counts. C1 only in a sentence that names the branch or its sign-off.
RE_C1="${RE_NUM} (signed-off )?commits?([^[:alnum:]]|\$)"
RE_C1CTX='[Ss]igned[- ]off|Signed-off-by|DCO|git commit -s|ahead of|(this|the) (branch|PR|MR)'
RE_C2="${RE_NUM} of ([0-9]{1,5}) commits"
RE_D1="${RE_NUM} (files? changed|changed files?)"
RE_D2='\(([0-9]{1,5}) files?, [+]'
# Cited commits: URLs are blanked first; H1 backticked, H2 bare with >= 1 digit and >= 1
# of a-f (A1: `]` first in the trailing class, no backslash in the leading one).
RE_URL='https?://[^[:space:])>]+'
# The sign-off box: a ticked list item naming the sign-off, on a line without `not ` or
# `unsigned`.
RE_B1='^[[:space:]]*[-*+][[:space:]]+(\[[xX]\][[:space:]].*([Ss]igned[- ]off|DCO).*)$'
# shellcheck disable=SC2016  # the backticks are literal markdown, not a command
RE_H1='`([0-9a-f]{7,40})`'
RE_H2='(^|[[:space:]([])([0-9a-f]{7,40})([][:space:]).,;:]|$)'
RE_EVAT='^(.+) @ ([0-9a-f]{40})$'
RE_EVBATS='^([0-9]{1,9})/([0-9]{1,9}) bats(, ([0-9]{1,9}) pytest)?$'
RE_EVPY='^([0-9]{1,9}) pytest$'
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

# _class <path> - CLS by basename: bats | pytest | other (another framework) | "". Leading
# dashes are ignored here: P admits them only so _path can refuse the token.
_class() {
  local b="${1##*/}"
  b="${b#"${b%%[!-]*}"}"
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
    if [[ "$l" == *@test* ]] && [[ "$l" =~ $RE_TEST ]]; then n=$((n + 1)); fi
  done <<<"$content"
  BCACHE[$key]=$n; BC=$n
}

# _bats_claim <L> <claim> <path token> <text before the count> <N> - one bats per-file
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

# ---- pytest counts (imPlan "pytest-count", U6) ----------------------------------------
# The gates run ONCE, lazily, at the first pytest claim that reaches them (no pytest claim:
# no resolver, no collection). Each failing gate makes every pytest count NOT CHECKED with
# its reason, in this order: an override that is not executable (checked before the resolve,
# so python_interp_resolve's die is unreachable); the newest artifact's python: line absent
# or (none) (read before the resolve, so no probe runs); the resolved interpreter not
# string-equal to it (another host, or an override spelled differently: no normalisation);
# the interpreter missing; a dirty tree; no timeout(1). The resolve runs with
# PYTHONDONTWRITEBYTECODE=1 as an env prefix (its probe loads conftest; a subshell would
# lose the setter-global), with cwd = the tree.
PY_GATE_DONE=false; PY_GATE=""; PY=""
declare -A PCACHE=() PCWHY=()
_py_gate() {
  local art rec="" l st
  if $PY_GATE_DONE; then return 0; fi
  PY_GATE_DONE=true
  if [ -n "${DEVAGENT_PYTEST_PYTHON:-}" ] && ! command -v "$DEVAGENT_PYTEST_PYTHON" >/dev/null 2>&1 \
     && [ ! -x "$DEVAGENT_PYTEST_PYTHON" ]; then
    PY_GATE="override not executable: $DEVAGENT_PYTEST_PYTHON"; return 0
  fi
  art="$(evidence_newest_artifact "$issue_dir")"
  if [ -n "$art" ]; then
    while IFS= read -r l; do
      case "$l" in 'python: '*) rec="${l#python: }"; rec="${rec%$'\r'}"; break ;; esac
    done < "$art"
  fi
  if [ -z "$rec" ] || [ "$rec" = '(none)' ]; then PY_GATE="suite run recorded no interpreter"; return 0; fi
  PYTHONDONTWRITEBYTECODE=1 python_interp_resolve "$work_dir" \
    "$(config_get_project_field "$project" source_dir 2>/dev/null || true)"
  PY="$PYTHON_INTERP"
  if [ "$rec" != "$PY" ]; then PY_GATE="interpreter differs from the suite run's: $rec vs $PY"; return 0; fi
  if ! command -v "$PY" >/dev/null 2>&1; then PY_GATE="interpreter missing: $PY"; return 0; fi
  st="$(GIT_OPTIONAL_LOCKS=0 _git status --porcelain)" || _cnr "git status --porcelain failed in $work_dir"
  if [ -n "$st" ]; then PY_GATE="dirty tree"; return 0; fi
  if ! command -v timeout >/dev/null 2>&1; then PY_GATE="timeout(1) not on PATH"; return 0; fi
  config_suite_env_resolve "$project"
}

# _py_collect <tracked path> - PC: its collected test ids, or PCW: why not. Once per path,
# bounded; rc 124/137 is read FIRST (a timed-out child's code is no status). rc 5 is
# "no tests" (0); rc 0 is compared only when there are >= 1 `::` ids and a summary
# `N tests collected` equal to them (`addopts = -q` makes -q into -qq: only `file: N`).
_py_collect() {
  local path="$1" out rc=0 l ids=0 sum=""
  if [ -n "${PCACHE[$path]+x}" ]; then PC="${PCACHE[$path]}"; PCW="${PCWHY[$path]}"; return 0; fi
  PC=""; PCW=""
  out="$(bounded_call "$collect_timeout" env "${SUITE_CHILD_UNSET[@]}" \
           "${SUITE_ENV_ASSIGNMENTS[@]+"${SUITE_ENV_ASSIGNMENTS[@]}"}" PYTHONDONTWRITEBYTECODE=1 \
           "$PY" -m pytest -p no:cacheprovider --collect-only -q "./$path" 2>/dev/null)" || rc=$?
  case "$rc" in
    124|137) PCW="collection timed out" ;;
    5) PC=0 ;;
    0)
      while IFS= read -r l; do
        l="${l%$'\r'}"
        if [[ "$l" == *::* ]]; then ids=$((ids + 1))
        elif [[ "$l" =~ $RE_COLLECTED ]]; then sum="${BASH_REMATCH[1]}"
        fi
      done <<<"$out"
      if [ "$ids" -ge 1 ] && [ "$sum" = "$ids" ]; then PC="$ids"; else PCW="collection output not parseable"; fi ;;
    *) PCW="collection failed (exit $rc)" ;;
  esac
  PCACHE["$path"]="$PC"; PCWHY["$path"]="$PCW"
}

# _pytest_claim <L> <claim> <path token> <text before the count> <N> - one pytest count.
# Any at-commit qualifier, HEAD included, is NOT CHECKED "measured at <tok>": the
# collection runs on the tree, never at a commit (a miss, never a false report).
_pytest_claim() {
  local L="$1" claim="$2" path="$3" before="$4" n="$5"
  _qual "$before"
  if [ -n "$QUAL" ]; then _nc "$L" pytest-count "$claim" "$QUAL"; return 0; fi
  if [ -n "$AT_TOK" ]; then _nc "$L" pytest-count "$claim" "measured at $AT_TOK"; return 0; fi
  _path "$path"
  if [ -z "$RP" ]; then _nc "$L" pytest-count "$claim" "$RP_WHY"; return 0; fi
  _py_gate
  if [ -n "$PY_GATE" ]; then _nc "$L" pytest-count "$claim" "$PY_GATE"; return 0; fi
  _py_collect "$RP"
  if [ -n "$PCW" ]; then _nc "$L" pytest-count "$claim" "$PCW"; return 0; fi
  _num "$n"
  _counted pytest-count
  [ "$NUM" != "$PC" ] || return 0
  # NUM < PC without arithmetic on an mr.md number (Issue-774): both are digit strings with
  # no leading zero, so a shorter one is smaller and equal lengths compare bytewise.
  # shellcheck disable=SC2071  # a string comparison on purpose (above)
  if [[ "$claim" =~ $RE_PASSW ]] && [ "${#NUM}" -le "${#PC}" ] && { [ "${#NUM}" -lt "${#PC}" ] || [[ "$NUM" < "$PC" ]]; }; then
    _mm "$L" pytest-count "$claim" "$NUM" "$PC" "collected at HEAD; a pass count below it can be true when tests skip or xfail"
  else
    _mm "$L" pytest-count "$claim" "$NUM" "$PC" "collected at HEAD"
  fi
}

# _scan_counts <L> <sentence> - the per-file count forms F1-F4 (imPlan "Per-file count").
# The window W runs from P's end (past its backtick) to the next P-shaped token, a `;`
# or the sentence end, at most 40 bytes, and must open with the connector.
_scan_counts() {
  local L="$1" s="$2" k np pstart pend p cls kind after lim w conn r n cpos cend cstart claim bd before between
  _p_spans "$s"
  local -a ps=("${P_S[@]+"${P_S[@]}"}") pe=("${P_E[@]+"${P_E[@]}"}")
  np=${#ps[@]}
  for ((k = 0; k < np; k++)); do
    pstart=${ps[k]}; pend=${pe[k]}; p="${s:pstart:pend-pstart}"
    _class "$p"; cls="$CLS"
    case "$cls" in bats) kind=bats-count ;; pytest) kind=pytest-count ;; '') continue ;; *) kind=test-count ;; esac
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
          PF_SEEN=1                       # a per-file recognition all the same (A9)
          _nc "$L" "$kind" "$claim" "count for several files"; continue
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
    if [[ "$s" =~ $RE_SKIPS ]] && [ "$cls" != other ]; then
      _nc "$L" "$kind" "$claim" "the line counts skipped or xfailed tests apart"; continue
    fi
    case "$cls" in
      bats)   _bats_claim "$L" "$claim" "$p" "${s:0:cpos}" "$n" ;;
      pytest) _pytest_claim "$L" "$claim" "$p" "${s:0:cpos}" "$n" ;;
      other)  _nc "$L" "$kind" "$claim" "another framework" ;;
    esac
  done
}

# ---- suite totals (imPlan "Suite total") -------------------------------------------------
# _mask <var> <start> <end> - overwrite [start,end) of the named string with '#', so the
# next leftmost search finds the next claim and '#' fails every NUM left boundary.
_mask() {
  local -n _mv="$1"
  local fill
  printf -v fill '%*s' "$(( $3 - $2 ))" ''
  _mv="${_mv:0:$2}${fill// /#}${_mv:$3}"
}

# _code_spans <text> - CS_S[]/CS_E[]: its inline code spans. A run of k backticks opens
# one, the next run of exactly k closes it; an unmatched run is literal.
_code_spans() {
  local s="$1" n=${#1} i=0 k j r found
  CS_S=(); CS_E=()
  while [ "$i" -lt "$n" ]; do
    if [ "${s:i:1}" != '`' ]; then i=$((i + 1)); continue; fi
    k=0; while [ "${s:i+k:1}" = '`' ]; do k=$((k + 1)); done
    j=$((i + k)); found=""
    while [ "$j" -lt "$n" ]; do
      if [ "${s:j:1}" = '`' ]; then
        r=0; while [ "${s:j+r:1}" = '`' ]; do r=$((r + 1)); done
        if [ "$r" -eq "$k" ]; then found=$j; break; fi
        j=$((j + r))
      else
        j=$((j + 1))
      fi
    done
    if [ -n "$found" ]; then CS_S+=("$i"); CS_E+=("$((found + k))"); i=$((found + k)); else i=$((i + k)); fi
  done
}
# _in_code <offset> - true when the offset lies inside one of CS_S/CS_E.
_in_code() {
  local x
  for x in "${!CS_S[@]}"; do
    if [ "$1" -ge "${CS_S[x]}" ] && [ "$1" -lt "${CS_E[x]}" ]; then return 0; fi
  done
  return 1
}

# The ## Evidence suite: line of mr.md itself (never the artifact): the first column-0
# suite: line in the block, as preship-evidence.sh reads it. It must parse and name HEAD.
EV_STATE=absent; EV_NONE=false; EV_OK=""; EV_PLAN=""; EV_PY=""
_ev_read() {
  local l in_b=false v parts
  for l in "${LINES[@]+"${LINES[@]}"}"; do
    l="${l%$'\r'}"
    if [[ "$l" == '## Evidence'* ]]; then in_b=true; continue; fi
    if [[ "$l" == '## '* ]]; then in_b=false; fi
    if $in_b && [[ "$l" =~ $RE_EVLINE ]]; then v="${BASH_REMATCH[1]}"; break; fi
  done
  [ -n "${v+x}" ] || return 0
  EV_STATE=bad
  [[ "$v" =~ $RE_EVAT ]] && [ "${BASH_REMATCH[2]}" = "$head_sha" ] || return 0
  parts="${BASH_REMATCH[1]}"
  if [ "$parts" = none ]; then EV_STATE=ok; EV_NONE=true
  elif [[ "$parts" =~ $RE_EVBATS ]]; then
    EV_STATE=ok; _num "${BASH_REMATCH[1]}"; EV_OK="$NUM"; _num "${BASH_REMATCH[2]}"; EV_PLAN="$NUM"
    if [ -n "${BASH_REMATCH[4]}" ]; then _num "${BASH_REMATCH[4]}"; EV_PY="$NUM"; fi
  elif [[ "$parts" =~ $RE_EVPY ]]; then EV_STATE=ok; _num "${BASH_REMATCH[1]}"; EV_PY="$NUM"
  fi
}
# _ev_need <bats|pytest|any> - EVW: why the Evidence suite: line cannot answer, or "".
_ev_need() {
  EVW=""
  case "$EV_STATE" in
    absent) EVW="no Evidence suite: line"; return 0 ;;
    bad)    EVW="Evidence suite: line is not at HEAD"; return 0 ;;
  esac
  if $EV_NONE && [ "$1" = any ]; then EVW="Evidence suite: line has no figures"; return 0; fi
  case "$1" in
    bats)   [ -n "$EV_PLAN" ] || EVW="Evidence suite: line has no bats figures" ;;
    pytest) [ -n "$EV_PY" ] || EVW="Evidence suite: line has no pytest figures" ;;
  esac
}
# _total_qual <sentence> <offset of the count> [s2] - TQ: the NOT CHECKED reason from a
# total's qualifiers, in the order earlier, partial, `after … (<sha>)` (S2 only),
# at-commit (A6). Any at-commit qualifier, the word HEAD and the HEAD sha included, is
# "measured at <tok>".
_total_qual() {
  TQ=""
  _qual "${1:0:$2}"
  if [ -n "$QUAL" ]; then TQ="$QUAL"; return 0; fi
  if [ "${3:-}" = s2 ] && [[ "$1" =~ $RE_AFTER ]]; then TQ="measured at ${BASH_REMATCH[3]}"; return 0; fi
  if [ -n "$AT_TOK" ]; then TQ="measured at $AT_TOK"; fi
}
# _total_gate <L> <sentence> <offset> <claim> <bats|pytest|any> [s2] - return 1, after
# printing its NOT CHECKED line, when a qualifier or the Evidence suite: line rules the
# total out.
_total_gate() {
  _total_qual "$2" "$3" "${6:-}"
  if [ -n "$TQ" ]; then _nc "$1" suite-total "$4" "$TQ"; return 1; fi
  _ev_need "$5"
  if [ -n "$EVW" ]; then _nc "$1" suite-total "$4" "$EVW"; return 1; fi
}
_cmp_total() { [ "$3" = "$4" ] || _mm "$1" suite-total "$2" "$3" "$4" "Evidence suite:"; }

# _scan_totals <L> <sentence> - S1, S2, then S3 when neither consumed the sentence. Read
# only in a sentence with no per-file claim (any F1-F4 recognition, A9).
_scan_totals() {
  local L="$1" s="$2" w m g1 pre ns ke a b n rest claim lab form x found consumed=0 cs=false
  local -a opts=()
  [ "$PF_SEEN" -eq 0 ] || return 0
  w="$s"
  while [[ "$w" =~ $RE_S1 ]]; do                                   # S1: <ok>/<plan> bats
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"; a="${BASH_REMATCH[2]}"; b="${BASH_REMATCH[3]}"
    pre="${w%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ${#pre} + ${#m} ))
    _mask w "$ns" "$ke"; consumed=1; claim="${s:ns:ke-ns}"
    _total_gate "$L" "$s" "$ns" "$claim" bats || continue
    _num "$a"; a="$NUM"; _num "$b"; b="$NUM"
    _counted suite-total
    _cmp_total "$L" "$claim" "$a/$b" "$EV_OK/$EV_PLAN"
  done
  w="$s"
  while [[ "$w" =~ $RE_S2 ]]; do                                   # S2: <n> pytest
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
    pre="${w%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ns + ${#n} + 7 ))
    _mask w "$ns" "$ke"; rest="${s:ke}"
    # Not a claim: T8 `pytest-`, T2 `pytest test(s)/case(s)`, T8 an unlisted noun after
    # pytest (a miss, never a report), a quote inside an inline code span.
    if [[ "$rest" == -* ]] || [[ "$rest" =~ $RE_T2 ]]; then continue; fi
    if [[ "$rest" =~ $RE_NOUN ]] && [[ "$S2_WORDS" != *" ${BASH_REMATCH[1]} "* ]]; then continue; fi
    if ! $cs; then _code_spans "$s"; cs=true; fi
    if _in_code "$ns"; then continue; fi
    consumed=1; claim="${s:ns:ke-ns}"
    _total_gate "$L" "$s" "$ns" "$claim" pytest s2 || continue
    _num "$n"
    _counted suite-total
    _cmp_total "$L" "$claim" "$NUM" "$EV_PY"
  done
  [ "$consumed" -eq 0 ] || return 0
  [[ "${s,,}" =~ $RE_S3 ]] || return 0                             # S3: the whole suite
  lab="${BASH_REMATCH[2]# }"
  if [[ "$s" =~ $RE_AB ]]; then
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"; a="${BASH_REMATCH[2]}"; b="${BASH_REMATCH[3]}"; form=ab
  elif [[ "$s" =~ $RE_S3N ]]; then
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"; a="${BASH_REMATCH[2]}"; b=""; form=n
  else
    return 0
  fi
  pre="${s%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ${#pre} + ${#m} )); claim="${s:ns:ke-ns}"
  _total_gate "$L" "$s" "$ns" "$claim" "${lab:-any}" || return 0
  _num "$a"; a="$NUM"; [ -z "$b" ] || { _num "$b"; b="$NUM"; }
  _counted suite-total
  case "$lab:$form" in
    bats:ab)  _cmp_total "$L" "$claim" "$a/$b" "$EV_OK/$EV_PLAN" ;;
    bats:n)   _cmp_total "$L" "$claim" "$a" "$EV_PLAN" ;;
    pytest:*) x="${b:-$a}"; _cmp_total "$L" "$claim" "$x" "$EV_PY" ;;
    *)
      # Unlabelled (Issue-118): reported only when it equals none of the bats plan, the
      # pytest n and their sum. Evidence figures are <= 9 digits, so the sum is exact.
      x="${b:-$a}"; found=""
      [ -z "$EV_PLAN" ] || opts+=("$EV_PLAN (bats)")
      [ -z "$EV_PY" ] || opts+=("$EV_PY (pytest)")
      if [ -n "$EV_PLAN" ] && [ -n "$EV_PY" ]; then opts+=("$(( 10#$EV_PLAN + 10#$EV_PY )) (both)"); fi
      for m in "${opts[@]}"; do [ "$x" != "${m%% *}" ] || return 0; done
      for m in "${!opts[@]}"; do
        if [ "$m" -eq 0 ]; then found="${opts[m]}"
        elif [ "$m" -eq $(( ${#opts[@]} - 1 )) ]; then found+=" or ${opts[m]}"
        else found+=", ${opts[m]}"; fi
      done
      _mm "$L" suite-total "$claim" "$x" "$found" "Evidence suite:" ;;
  esac
}

# ---- commit and file counts --------------------------------------------------------------
# Compared with `git rev-list --count <baseline_sha>..HEAD` and evidence_files_count (the
# preship checker's files: count), each computed once. Qualifiers as for totals: earlier,
# partial, then any at-commit (decision 4: a miss, never a false report).
N_COMMITS=""; N_FILES=""
_n_commits() {
  [ -z "$N_COMMITS" ] || return 0
  N_COMMITS="$(_git rev-list --count "$baseline_sha..HEAD")" \
    || _cnr "git rev-list --count ${baseline_sha:0:12}..HEAD failed in $work_dir"
}
_n_files() {
  [ -z "$N_FILES" ] || return 0
  evidence_files_count "$work_dir" "$baseline_sha" \
    || _cnr "git diff --name-only ${baseline_sha:0:12}..HEAD failed in $work_dir"
  N_FILES="$EVIDENCE_FILES_COUNT"
}
# _count_claim <L> <kind> <sentence> <offset of the count> <claim> <N>
_count_claim() {
  local L="$1" kind="$2" found
  _total_qual "$3" "$4"
  if [ -n "$TQ" ]; then _nc "$L" "$kind" "$5" "$TQ"; return 0; fi
  if [ "$kind" = commit-count ]; then _n_commits; found="$N_COMMITS"; else _n_files; found="$N_FILES"; fi
  _num "$6"
  _counted "$kind"
  [ "$NUM" = "$found" ] || _mm "$L" "$kind" "$5" "$NUM" "$found" "${baseline_sha:0:12}..HEAD"
}
# _scan_commits <L> <sentence> - C2 first; its span is masked, so a C1 number inside a
# C2 match is skipped (A12). Then D1 and D2.
_scan_commits() {
  local L="$1" s="$2" w m g1 pre ns ke
  w="$s"
  while [[ "$w" =~ $RE_C2 ]]; do
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"
    pre="${w%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ${#pre} + ${#m} ))
    _mask w "$ns" "$ke"
    _count_claim "$L" commit-count "$s" "$ns" "${s:ns:ke-ns}" "${BASH_REMATCH[3]}"
  done
  if [[ "$s" =~ $RE_C1CTX ]]; then
    while [[ "$w" =~ $RE_C1 ]]; do
      m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"
      pre="${w%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ${#pre} + ${#m} - ${#BASH_REMATCH[4]} ))
      _mask w "$ns" "$ke"
      _count_claim "$L" commit-count "$s" "$ns" "${s:ns:ke-ns}" "${BASH_REMATCH[2]}"
    done
  fi
  w="$s"
  while [[ "$w" =~ $RE_D1 ]]; do
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"
    pre="${w%%"$m"*}"; ns=$(( ${#pre} + ${#g1} )); ke=$(( ${#pre} + ${#m} ))
    _mask w "$ns" "$ke"
    _count_claim "$L" files-count "$s" "$ns" "${s:ns:ke-ns}" "${BASH_REMATCH[2]}"
  done
  while [[ "$w" =~ $RE_D2 ]]; do
    m="${BASH_REMATCH[0]}"
    pre="${w%%"$m"*}"; ns=$(( ${#pre} + 1 )); ke=$(( ${#pre} + ${#m} - 3 ))
    _mask w "$((ns - 1))" "$ke"
    _count_claim "$L" files-count "$s" "$ns" "${s:ns-1:ke-ns+1}" "${BASH_REMATCH[1]}"
  done
}

# ---- cited commits (the AC as amended 2026-11-15) ----------------------------------------
# A cited token (H1, H2, or an at-commit 7-40 hex token) must resolve to one local commit
# (rev-parse rc 1: NOT CHECKED), then be reachable from HEAD, or else from the baseline
# ref (baseline_ref_name: default_baseline or the #162 marker; no fetch). Neither is a
# MISMATCH; an unresolvable ref is NOT CHECKED. Decided once per token.
BREF=""; BREF_SHA=""; BREF_DONE=false
_base_ref() {
  local rc=0
  if $BREF_DONE; then return 0; fi
  BREF_DONE=true
  baseline_ref_name "$project" "$issue_dir"     # setter-globals; never $( … )
  BREF="$BASELINE_REF"
  BREF_SHA="$(_git rev-parse --verify --quiet "$BREF^{commit}" 2>/dev/null)" || rc=$?
  case "$rc" in 0) ;; 1) BREF_SHA="" ;; *) _cnr "git rev-parse $BREF^{commit} failed (exit $rc) in $work_dir" ;; esac
}
declare -A CITED=()
# _cited <L> <token> - one cited token: CITED caches ok | nc:<reason> | mm.
_cited() {
  local L="$1" tok="$2" c rc v
  if [ -z "${CITED[$tok]+x}" ]; then
    _resolve "$tok"
    if [ -z "$RES" ]; then
      v="nc:$tok resolves to no single local commit"
    else
      c="$RES"; rc=0; _gitt merge-base --is-ancestor "$c" HEAD || rc=$?
      case "$rc" in
        0) v=ok ;;
        1) _base_ref
           if [ -z "$BREF_SHA" ]; then
             v="nc:not reachable from HEAD, and $BREF does not resolve here"
           else
             rc=0; _gitt merge-base --is-ancestor "$c" "$BREF_SHA" || rc=$?
             case "$rc" in
               0) v=ok ;; 1) v=mm ;;
               *) _cnr "git merge-base --is-ancestor ${c:0:12} $BREF failed (exit $rc) in $work_dir" ;;
             esac
           fi ;;
        *) _cnr "git merge-base --is-ancestor ${c:0:12} HEAD failed (exit $rc) in $work_dir" ;;
      esac
    fi
    CITED["$tok"]="$v"
  fi
  v="${CITED[$tok]}"
  case "$v" in
    nc:*) _nc "$L" cited-commit "$tok" "${v#nc:}" ;;
    ok) _counted cited-commit ;;
    mm) _counted cited-commit
        _mm "$L" cited-commit "$tok" "a commit on the branch or $BREF" "local commit reachable from neither HEAD nor $BREF" "$BREF" ;;
  esac
}
# _scan_cited <L> <sentence> - each distinct cited token of the sentence, once.
_scan_cited() {
  local L="$1" s="$2" w m g1 pre tok
  local -a toks=()
  local -A seen=()
  w="$s"
  while [[ "$w" =~ $RE_URL ]]; do
    m="${BASH_REMATCH[0]}"; pre="${w%%"$m"*}"; _mask w "${#pre}" "$(( ${#pre} + ${#m} ))"
  done
  while [[ "$w" =~ $RE_H1 ]]; do
    m="${BASH_REMATCH[0]}"; toks+=("${BASH_REMATCH[1]}"); pre="${w%%"$m"*}"
    _mask w "${#pre}" "$(( ${#pre} + ${#m} ))"
  done
  while [[ "$w" =~ $RE_H2 ]]; do
    m="${BASH_REMATCH[0]}"; g1="${BASH_REMATCH[1]}"; tok="${BASH_REMATCH[2]}"; pre="${w%%"$m"*}"
    _mask w "$(( ${#pre} + ${#g1} ))" "$(( ${#pre} + ${#g1} + ${#tok} ))"
    if [[ "$tok" == *[0-9]* && "$tok" == *[a-f]* ]]; then toks+=("$tok"); fi
  done
  if [[ "$AT_TOK" =~ $RE_HEX ]]; then toks+=("$AT_TOK"); fi
  for tok in "${toks[@]+"${toks[@]}"}"; do
    [ -z "${seen[$tok]+x}" ] || continue
    seen["$tok"]=1
    _cited "$L" "$tok"
  done
}

# ---- the sign-off box -----------------------------------------------------------------
# Every commit in <baseline_sha>..HEAD, merges included, must carry a non-empty
# Signed-off-by trailer; the MISMATCH names each sha12 that lacks one. Decided once.
SIGNOFF_DONE=false; UNSIGNED=""
_unsigned() {
  local out l sha
  if $SIGNOFF_DONE; then return 0; fi
  SIGNOFF_DONE=true
  out="$(_git log --format='%H%x09%(trailers:key=Signed-off-by,valueonly,separator=%x2C)' "$baseline_sha..HEAD")" \
    || _cnr "git log ${baseline_sha:0:12}..HEAD failed in $work_dir"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    sha="${l%%$'\t'*}"
    if [ -z "${l#*$'\t'}" ]; then UNSIGNED+="${UNSIGNED:+, }${sha:0:12}"; fi
  done <<<"$out"
}
# _scan_signoff <L> <line text>
_scan_signoff() {
  local claim
  [[ "$2" =~ $RE_B1 ]] || return 0
  claim="${BASH_REMATCH[1]}"
  if [[ "$2" == *'not '* || "$2" == *unsigned* ]]; then return 0; fi
  _unsigned
  _counted signoff
  [ -z "$UNSIGNED" ] \
    || _mm "$1" signoff "$claim" "every commit signed off" "unsigned $UNSIGNED" "${baseline_sha:0:12}..HEAD"
}

# _scan_sentence <L> <sentence>
_scan_sentence() {
  PF_SEEN=0
  _at_commit "$2"
  if [[ "$2" == *[0-9]* ]]; then             # every count, total and commit form has one
    _scan_counts "$1" "$2"
    _scan_totals "$1" "$2"
    _scan_commits "$1" "$2"
  fi
  _scan_cited "$1" "$2"
}

# ---- the scan ---------------------------------------------------------------------------
# Lines in mr.md order; one CR stripped. Skipped: the ## Evidence block (bounded as
# preship-evidence.sh bounds it, ignoring fences: A11), fenced blocks (a fence closes on
# the marker that opened it), and <!-- --> comments. A sentence is a split of one line on
# ". " and never spans lines (A2).
mapfile -t LINES < "$mr"
_ev_read
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
  _scan_signoff "$L" "$rest"
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
