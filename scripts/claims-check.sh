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
declare -A TRACKED=()
mapfile -d '' -t _ls < <(_git ls-tree -r -z --name-only HEAD)
wait "$!" || _cnr "git ls-tree -r -z --name-only HEAD failed in $work_dir"
for _p in "${_ls[@]+"${_ls[@]}"}"; do TRACKED["$_p"]=1; done

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

_finish
