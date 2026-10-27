#!/usr/bin/env bash
# scripts/evidence-stamp.sh — #894. Writes the three machine-checked lines of mr.md's
# ## Evidence block from the newest suite-count artifact and git, so no model retypes
# them: preship's check failed three times on a hand-copied short SHA, and every commit
# after draftmr left the block stale with nothing to refresh it.
#   suite:     the canonical line rebuilt from the artifact (<parts> @ <full head sha>)
#   files:     <n> changed, n = git diff --name-only <baseline_sha>..HEAD
#   platform:  the artifact's own platform: line, verbatim
# The lines come from scripts/lib/evidence.sh, the functions preship-evidence.sh checks
# them with (D2: one sourced helper, not a checker print mode), so the writer and the
# checker cannot rebuild a line two ways.
#
#   usage: evidence-stamp.sh <project> <Issue-N> [--attest-tree '<attestation>']
#
# Callers: draftmr (core-draft-mr fills the Evidence block with it), and review / redmr
# after any commit they make (D3). It re-stamps at those commits and NOT inside preship: preship checks this block,
# and stamping there would make the check compare its own output (register Issue-353);
# the preship verifier is forbidden to run it. A commit made by hand outside review and
# redmr is not an --auto chain: preship still fails it, and its suite-line mismatch
# names this script.
# ISSUE (D4, run-suite's #659 precedence): the <Issue-N> argument, else the session's
# DEVAGENT_ACTIVE_ISSUE pin, else refuse ISSUE UNSTATED. The shared issue_dir slot is
# never the source for a write. The tree is the issue's worktree_path, else source_dir
# (active_tree_resolve), after the scope and tree guards.
# --attest-tree (also spelled --attest-tree=<attestation>) is preship-evidence.sh's, with
# the same grammar and validation (the lib's tree rung): an artifact whose tree: does not
# exist here (the WSL clone's, stamped from Windows) is refused TREE UNATTESTED unless
# the caller attests that tree for this run.
# What it refuses (D5), changing nothing: no artifact; head: is not HEAD (STALE
# ARTIFACT); dirty: is not no; a tree-rung failure; no platform: line, or a malformed
# one; and pytest: (error) or an unparseable framework line. Each names the remedy:
# re-run run-suite in the tree being shipped, then this script. It does NOT judge green:
# a red but well-formed artifact is stamped as measured, and preship fails it.
# Structural problems with mr.md die first and alone (no mr.md, two ## Evidence
# headings, a duplicated or missing suite: line, NUL bytes, no baseline_sha). An mr.md
# with no ## Evidence block is the #149 shape: a warning, rc 0, nothing written.
# D6: a git diff that fails while counting files: dies; it is never written as 0.
# REWRITE RULES (D-R). The block runs from the first line starting '## Evidence' to the
# line before the next '## ' line, or EOF (one trailing CR ignored when matching, as the
# checker's grep and awk read it). Only column-0 suite:, files: and platform: lines in it
# change; an indented comment and a suite: line outside the block never match. Each
# replaced line keeps its own terminator (CRLF, LF, or none at EOF). A missing files:
# goes directly after suite:, a missing platform: directly after files:, each taking the
# terminator of the line above it (when that line ended the file unterminated, it gains
# the file's first terminator, LF if none, and the inserted line stays unterminated).
# The read and rewrite are bash builtins only: Git Bash's text tools hide CR. The new
# bytes go to a temp copy (cp -p keeps the mode), then replace mr.md with one mv; equal
# bytes are a no-op, reported 'unchanged'. Exit 0 stamped or unchanged, 1 refused or
# died, 2 usage. A CRLF block keeps its CRs; it passes the checker on GNU userlands only
# once #849 lands.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=lib/platform.sh
. "$DEVAGENT_ROOT/scripts/lib/platform.sh"
# shellcheck source=lib/evidence.sh
. "$DEVAGENT_ROOT/scripts/lib/evidence.sh"

: "${DEVAGENT_GIT:=git}"

usage="usage: evidence-stamp.sh <project> <Issue-N> [--attest-tree '<attestation>']"
_usage_err() { printf 'evidence-stamp: %s\n%s\n' "$1" "$usage" >&2; exit 2; }

attest_tree=""; _attest_seen=false; _pos=()
_attest_take() {   # <value>
  [ -n "$1" ] || _usage_err "--attest-tree needs a value: 'head=<full sha> dirty=no path=<tree>' (#655)"
  ! $_attest_seen || _usage_err "--attest-tree given more than once — pass one attestation per run (#655)"
  _attest_seen=true; attest_tree="$1"
}
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) printf '%s\n' "$usage"; exit 0 ;;
    --attest-tree) _attest_take "${2-}"; shift 2 ;;
    --attest-tree=*) _attest_take "${1#*=}"; shift ;;
    --*) _usage_err "unknown option '$1'" ;;
    *) _pos+=("$1"); shift ;;
  esac
done
[ "${#_pos[@]}" -le 2 ] || _usage_err "too many arguments: ${_pos[*]}"

active_resolve_project_try "${_pos[0]:-}" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
[ -n "$project" ] || die "evidence-stamp: project required (no arg and no active project)"
config_is_project "$project" || die "evidence-stamp: unknown project '$project'"
active_guard_scope evidence-stamp
issue_arg="${_pos[1]:-}"
if [ -z "$issue_arg" ] && [ -z "${DEVAGENT_ACTIVE_ISSUE:-}" ]; then
  die "evidence-stamp: ISSUE UNSTATED — no issue was passed and DEVAGENT_ACTIVE_ISSUE is not set; pass it: evidence-stamp.sh <project> <Issue-N> (#659: the shared issue_dir slot is never a source for a write)"
fi
active_resolve_issue_src "$project" "$issue_arg"   # setter-globals; never $( … )
issue="$ACTIVE_RESOLVED_ISSUE"
issue_dir="$(issue_context_dir "$project" "$issue")" \
  || die "evidence-stamp: could not derive the issue directory for $issue — is devdoc_dir configured for '$project'?"
[ -d "$issue_dir" ] || die "evidence-stamp: no issue directory for $issue: $issue_dir — pull the issue first, or check the id"
issue_label="$(basename "$issue_dir")"
mr="$issue_dir/mr.md"
[ -f "$mr" ] || die "evidence-stamp: no mr.md at $mr — /devagent:draftmr writes it first"
active_tree_resolve "$project" "$issue"   # setter-globals; never $( … )
active_guard_tree evidence-stamp          # strictly after active_guard_scope (#571)
work_dir="$ACTIVE_TREE_DIR"

# NUL bytes: a bash variable cannot carry one, so the rewrite would drop it. A NUL-
# delimited read succeeds only when it finds a NUL before EOF.
! IFS= read -r -d '' _ < "$mr" \
  || die "evidence-stamp: mr.md contains NUL bytes — refusing to rewrite it (bash cannot carry them, so bytes would be lost)"

# Read mr.md into lines (content, CR stripped) and their terminators, builtins only.
lines=(); terms=()
while :; do
  _l=""; _rc=0
  IFS= read -r _l || _rc=$?
  if [ "$_rc" -ne 0 ] && [ -z "$_l" ]; then break; fi
  _t=""; [ "$_rc" -ne 0 ] || _t=$'\n'
  if [[ "$_l" == *$'\r' ]]; then _l="${_l%$'\r'}"; _t=$'\r'"$_t"; fi
  lines+=("$_l"); terms+=("$_t")
  [ "$_rc" -eq 0 ] || break
done < "$mr"

# The block, and the three target lines in it (dies come before any refusal).
_ev_start=-1; _ev_heads=0
for _i in "${!lines[@]}"; do
  case "${lines[_i]}" in "## Evidence"*) _ev_heads=$((_ev_heads + 1)); [ "$_ev_start" -ge 0 ] || _ev_start="$_i" ;; esac
done
if [ "$_ev_heads" -eq 0 ]; then
  warn "evidence-stamp: mr.md has no '## Evidence' block — nothing to stamp (#149)"
  exit 0
fi
[ "$_ev_heads" -eq 1 ] || die "evidence-stamp: mr.md has $_ev_heads '## Evidence' headings — keep one"
_ev_end="${#lines[@]}"
for ((_i = _ev_start + 1; _i < ${#lines[@]}; _i++)); do
  case "${lines[_i]}" in "## "*) _ev_end="$_i"; break ;; esac
done
declare -A at=([suite]=-1 [files]=-1 [platform]=-1) seen=([suite]=0 [files]=0 [platform]=0)
for ((_i = _ev_start + 1; _i < _ev_end; _i++)); do
  for _k in suite files platform; do
    case "${lines[_i]}" in "$_k:"*) seen[$_k]=$((${seen[$_k]} + 1)); [ "${at[$_k]}" -ge 0 ] || at[$_k]="$_i" ;; esac
  done
done
for _k in suite files platform; do
  [ "${seen[$_k]}" -le 1 ] || die "evidence-stamp: mr.md's Evidence block has ${seen[$_k]} '$_k:' lines — keep one, then re-run"
done
[ "${at[suite]}" -ge 0 ] || die "evidence-stamp: mr.md's Evidence block has no 'suite:' line — restore the template's, then re-run"

# The artifact, and every reason it cannot honestly describe HEAD (accumulated).
_refuse() {   # <entry...>
  local f
  printf 'evidence-stamp: REFUSED — mr.md was not changed (#894)\n' >&2
  for f in "$@"; do printf '  - %s\n' "$f" >&2; done
  exit 1
}
remedy="run \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh\" $project $issue_label\` in the tree being shipped, then re-run \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/evidence-stamp.sh\" $project $issue_label\`"
# An attestation binds to one artifact's head: and tree:, so a re-run needs a new one.
[ -z "$attest_tree" ] || remedy+=" with a fresh --attest-tree for the new artifact's head (#655)"
artifact="$(evidence_newest_artifact "$issue_dir")"
[ -n "$artifact" ] || _refuse "no suite-count artifact in $issue_dir/analysis — $remedy"
cur_head="$("$DEVAGENT_GIT" -C "$work_dir" rev-parse HEAD 2>/dev/null || true)"
[ -n "$cur_head" ] || die "evidence-stamp: could not resolve HEAD in $work_dir"
fails=()
evidence_suite_resolve "$artifact"
evidence_tree_rung evidence-stamp "$artifact" "$EVIDENCE_A_HEAD" "$work_dir" "$attest_tree"
[ "$EVIDENCE_A_HEAD" = "$cur_head" ] \
  || fails+=("STALE ARTIFACT — $artifact records head $EVIDENCE_A_HEAD, but $work_dir is at $cur_head: it was measured before the latest commit — $remedy")
[ "$EVIDENCE_A_DIRTY" = "no" ] \
  || fails+=("the artifact records dirty: ${EVIDENCE_A_DIRTY:-(unreadable)}, so the suite ran on uncommitted changes — commit or clean $work_dir, then $remedy")
plat_line="$(evidence_platform_line "$artifact")"
if [ -z "$plat_line" ]; then
  fails+=("the artifact has no platform: line: it came from a run-suite that predates #654 (a clone running old plugin scripts) — $remedy, using this plugin's scripts")
else
  evidence_platform_check "$plat_line"
  [ -z "$EVIDENCE_PLATFORM_PROBLEM" ] || fails+=("$EVIDENCE_PLATFORM_PROBLEM")
fi
fails+=(${EVIDENCE_SUITE_PROBLEMS[@]+"${EVIDENCE_SUITE_PROBLEMS[@]}"})
[ "${#fails[@]}" -eq 0 ] || _refuse "${fails[@]}"

baseline="$(state_ctx_get "$project" baseline_sha "$issue" 2>/dev/null || true)"
case "$baseline" in null|'""') baseline="" ;; esac
[ -n "$baseline" ] || die "evidence-stamp: baseline_sha unset — cannot write files: (never diff against nothing)"
evidence_files_count "$work_dir" "$baseline" \
  || die "evidence-stamp: git diff $baseline..HEAD failed in $work_dir — cannot count files:, and a count git did not produce is never written (#894)"

# Rewrite: the three lines replaced in place, missing ones inserted (D-R5).
declare -A new=([suite]="suite: $EVIDENCE_SUITE_LINE" [files]="files: $EVIDENCE_FILES_COUNT changed" [platform]="$plat_line")
first_term=$'\n'
for _t in "${terms[@]}"; do
  if [ -n "$_t" ]; then first_term="$_t"; break; fi
done
out_l=(); out_t=()
_insert() {   # <line>: after the last output line, taking its terminator (D-R5)
  local n="${#out_t[@]}" t
  t="${out_t[n - 1]}"
  if [ -z "$t" ]; then out_t[n - 1]="$first_term"; fi
  out_l+=("$1"); out_t+=("$t")
}
for _i in "${!lines[@]}"; do
  _l="${lines[_i]}"
  for _k in suite files platform; do
    [ "${at[$_k]}" -ne "$_i" ] || _l="${new[$_k]}"
  done
  out_l+=("$_l"); out_t+=("${terms[_i]}")
  if [ "$_i" -eq "${at[suite]}" ] && [ "${at[files]}" -lt 0 ]; then
    _insert "${new[files]}"
    [ "${at[platform]}" -ge 0 ] || _insert "${new[platform]}"
  fi
  if [ "$_i" -eq "${at[files]}" ] && [ "${at[platform]}" -lt 0 ]; then
    _insert "${new[platform]}"
  fi
done
content=""; original=""
for _i in "${!out_l[@]}"; do content+="${out_l[_i]}${out_t[_i]}"; done
# lines[]/terms[] rebuild mr.md byte for byte (no NUL, checked above).
for _i in "${!lines[@]}"; do original+="${lines[_i]}${terms[_i]}"; done
if [ "$content" = "$original" ]; then
  info "evidence-stamp: unchanged — $mr already carries the lines of $artifact [tree=$EVIDENCE_TREE_VERDICT]"
  exit 0
fi

tmp="$(mktemp "$mr.stamp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp -p "$mr" "$tmp"
printf '%s' "$content" > "$tmp"
summary="suite: $EVIDENCE_SUITE_LINE; files: $EVIDENCE_FILES_COUNT changed; $plat_line"
mv -f "$tmp" "$mr"
info "evidence-stamp: stamped $mr from $artifact ($summary) [tree=$EVIDENCE_TREE_VERDICT]"
