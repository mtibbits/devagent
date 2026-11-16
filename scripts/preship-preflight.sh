#!/usr/bin/env bash
# scripts/preship-preflight.sh — #1122. The main-session preflight of /devagent:preship
# (commands/preship.md "Preflight (between 2 and 2a)"), as ONE script so every call the
# session makes is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/…"`, inside the plugin's
# allowed-tools grant (#548/#584): no compound shell, and no script stderr or mr.md text
# typed into a command line. It holds the evidence stop, the claims runs and their cap,
# the prior-decision lookup and the seven log spellings; the session keeps the judgment
# (the three correction rules) and the mr.md edits.
#
#   usage: preship-preflight.sh <subcommand> <project> <Issue-N> <issue-dir> [args]
#     evidence          preship-evidence.sh <project> <Issue-N> --attestable-exit, and a
#                       fresh preflight (the run count resets). Exit 0 or 4: continue (on 4
#                       only attestations are absent; the verifier attests). 9, 10 or 11:
#                       quarantine, passed through. Any other exit STOPS the step: an older
#                       preship.md moves to analysis/<date>-<HHMMSS>-preship-superseded.md
#                       (logged), and checklist-stuck.sh marks the step [!] with
#                       "preship: evidence preflight: <first failure line>". Exits the
#                       checker's code; prints "evidence rc=<rc>".
#     claims            one run of claims-check.sh <project> <Issue-N>, at most three per
#                       preflight (a fourth exits 2). Prints its output and
#                       "claims run <n> of 3, rc=<rc>"; exits its code.
#     prior <L>         exit 0 (printing the entry) when the log holds
#                       "claims: mr.md:<L> left as written: '<text>'" with <text> equal to
#                       line <L> now (truncated as logged); else exit 1.
#     save <L>          keep line <L> of mr.md, before an edit, for log corrected/named-commit.
#     log <kind> [<L>]  append the one spelling for <kind> through checklist-log.sh:
#                       corrected <L> | named-commit <L> | left-as-written <L> (the reason is
#                       the first line of <issue-dir>/.preflight-reason, which the session
#                       writes with its Write tool and this removes once logged; else of
#                       stdin) | unresolved <L> | could-not-run | preflight (then the
#                       preflight's state and any leftover reason file are removed).
# "First failure line" = stderr's first "  - " entry (plus "(+N more)"), else its first
# non-empty line, else "(no stderr)". Logged mr.md lines are truncated to 200 characters
# plus "…". Exits 2 on usage. Never runs run-suite.sh or the Evidence stamper.
# State between calls (the run count, the last exits, the last claims output, saved lines)
# lives in ${TMPDIR:-/tmp}/devagent-preflight-<uid>/<project>/<Issue-N>, mode 700, refused
# when another user owns it.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=lib/history.sh
. "$DEVAGENT_ROOT/scripts/lib/history.sh"
# shellcheck source=lib/utf8-locale.sh
. "$DEVAGENT_ROOT/scripts/lib/utf8-locale.sh"

usage="usage: preship-preflight.sh <subcommand> <project> <Issue-N> <issue-dir> [args], where <subcommand> [args] is evidence | claims | prior <L> | save <L> | log <kind> [<L>]"
_usage() { printf 'preship-preflight: %s\n%s\n' "$1" "$usage" >&2; exit 2; }

# `log <kind> <project> …` is read like `log <project> … <kind>`: the doc's `… log corrected <L>`
# shorthand reads both ways (two of three eval subjects wrote the kind first).
_kind_first=""
if [ "${1:-}" = log ]; then
  case "${2:-}" in corrected|named-commit|left-as-written|unresolved|could-not-run|preflight) _kind_first="$2"; set -- log "${@:3}" ;; esac
fi
[ "$#" -ge 4 ] || _usage "expected <subcommand> <project> <Issue-N> <issue-dir>"
sub="$1"; project="$2"; issue="$3"; issue_dir="${4%/}"; shift 4
[ -z "$_kind_first" ] || set -- "$_kind_first" "$@"
case "$issue" in ''|*[!A-Za-z0-9_-]*) _usage "'$issue' is not an issue id" ;; esac
case "$project" in ''|.|..|*[!A-Za-z0-9_.-]*) _usage "'$project' is not a project name" ;; esac
[ "$(basename -- "$issue_dir")" = "$issue" ] || _usage "issue dir '$issue_dir' is not $issue's"
[ -f "$issue_dir/checklist.md" ] || _usage "no checklist.md in '$issue_dir'"
quarantine_guard_dir "preship-preflight" "$issue_dir"
mr="$issue_dir/mr.md"

_line_arg() { case "${1:-}" in ''|*[!0-9]*|0*) _usage "a line number is required, got '${1:-}'" ;; esac; }
# _t <text> - the text, or its first 200 characters plus "…". Characters under a UTF-8
# locale whatever the session's, so a cut never splits one and `prior` matches across
# sessions (bytes only when the host has no UTF-8 locale).
utf8_locale_resolve || true
_t() {
  local LC_ALL="${UTF8_LOCALE:-${LC_ALL:-}}"
  if [ "${#1}" -gt 200 ]; then printf '%s…' "${1:0:200}"; else printf '%s' "$1"; fi
}
# _line <L> - LINE: line <L> of mr.md, one CR stripped ("" past the end).
_line() {
  local i=0 l
  LINE=""
  while IFS= read -r l || [ -n "$l" ]; do
    i=$((i + 1))
    if [ "$i" -eq "$1" ]; then LINE="${l%$'\r'}"; return 0; fi
  done < "$mr"
}
# _first <file> - FIRST: the file's first non-empty line ("" when none, or no file).
_first() {
  local l
  FIRST=""
  [ -f "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    if [ -n "$l" ]; then FIRST="$l"; return 0; fi
  done < "$1"
}
_log() { bash "$SCRIPTS/checklist-log.sh" "$issue_dir" preship "$1"; }

base="${TMPDIR:-/tmp}/devagent-preflight-$(id -u)"
state="$base/$project/$issue"
# The per-user base is private (700) and must be ours: checked here, before any subcommand
# reads, writes or removes $state, and everything below inherits it.
mkdir -m 700 "$base" 2>/dev/null || true
# shellcheck disable=SC2015  # die exits: a guard, not an if-then-else
[ ! -L "$base" ] && [ -d "$base" ] && [ -O "$base" ] \
  || die "preflight state dir $base is missing, a symlink, or not owned by $(id -un)"
chmod 700 "$base"
_state_ready() { mkdir -p "$state"; }
_get() { if [ -f "$state/$1" ]; then cat "$state/$1"; else printf '%s' "${2-}"; fi; }

case "$sub" in
  evidence)
    rm -rf -- "$state"; _state_ready; rm -f -- "$issue_dir/.preflight-reason"   # a fresh preflight
    rc=0
    bash "$SCRIPTS/preship-evidence.sh" "$project" "$issue" --attestable-exit 2>"$state/evidence.err" || rc=$?
    cat "$state/evidence.err" >&2
    printf '%s' "$rc" > "$state/evrc"
    case "$rc" in
      0|4|9|10|11) ;;
      *)
        first=""; more=0
        while IFS= read -r l || [ -n "$l" ]; do
          case "$l" in
            '  - '*) if [ -z "$first" ]; then first="${l#  - }"; else more=$((more + 1)); fi ;;
          esac
        done < "$state/evidence.err"
        if [ -z "$first" ]; then _first "$state/evidence.err"; first="$FIRST"; fi
        [ -n "$first" ] || first='(no stderr)'
        [ "$more" -eq 0 ] || first="$first (+$more more)"
        if [ -f "$issue_dir/preship.md" ]; then
          sup="analysis/$(date_tag)-$(date +%H%M%S)-preship-superseded.md"
          mkdir -p "$issue_dir/analysis"
          mv -- "$issue_dir/preship.md" "$issue_dir/$sup"
          _log "preflight: moved preship.md to $sup"
        fi
        bash "$SCRIPTS/checklist-stuck.sh" "$issue_dir" "preship: evidence preflight: $first" ;;
    esac
    printf 'evidence rc=%s\n' "$rc"
    exit "$rc" ;;
  claims)
    _state_ready
    n="$(_get runs 0)"
    [ "$n" -lt 3 ] || { printf 'preship-preflight: at most three runs of claims-check.sh per preflight; this was run four — log the lines still reported as unresolved\n' >&2; exit 2; }
    n=$((n + 1)); printf '%s' "$n" > "$state/runs"
    rc=0
    bash "$SCRIPTS/claims-check.sh" "$project" "$issue" >"$state/claims.out" 2>"$state/claims.err" || rc=$?
    printf '%s' "$rc" > "$state/rc"
    cat "$state/claims.out"; cat "$state/claims.err" >&2
    printf 'claims run %s of 3, rc=%s\n' "$n" "$rc"
    exit "$rc" ;;
  prior)
    _line_arg "${1:-}"; _line "$1"
    want="claims: mr.md:$1 left as written: '$(_t "$LINE")' — "
    while IFS='|' read -r ts _iss step msg; do
      if [ "$step" = preship ] && [[ "$msg" == "$want"* ]]; then printf 'prior: %s  %s: %s\n' "$ts" "$step" "$msg"; exit 0; fi
    done < <(history_parse_log "$issue_dir/checklist.md" "$issue")
    printf 'prior: no prior decision for mr.md:%s\n' "$1"
    exit 1 ;;
  save)
    _line_arg "${1:-}"; _state_ready; _line "$1"
    printf '%s\n' "$LINE" > "$state/old.$1"
    printf 'saved mr.md:%s\n' "$1" ;;
  log)
    kind="${1:-}"; shift || true
    case "$kind" in
      corrected|named-commit)
        _line_arg "${1:-}"; _line "$1"
        [ -f "$state/old.$1" ] || _usage "nothing saved for line $1: run 'save $1' before the edit"
        IFS= read -r old < "$state/old.$1" || true
        msg="claims: mr.md:$1 ${kind/-/ }: '$(_t "$old")' -> '$(_t "$LINE")'" ;;
      left-as-written)
        _line_arg "${1:-}"; _line "$1"
        # A file, not a heredoc: a multi-line command falls outside the plugin grant (Issue-584).
        why=""
        if [ -f "$issue_dir/.preflight-reason" ]; then IFS= read -r why < "$issue_dir/.preflight-reason" || true
        elif [ ! -t 0 ]; then IFS= read -r why || true
        fi
        why="${why%$'\r'}"
        [ -n "$why" ] || _usage "left-as-written needs a one-line reason in $issue_dir/.preflight-reason (write it with the Write tool first)"
        msg="claims: mr.md:$1 left as written: '$(_t "$LINE")' — $why" ;;
      unresolved)
        _line_arg "${1:-}"; _line "$1"
        msg="claims: mr.md:$1 unresolved after run $(_get runs 0): '$(_t "$LINE")'" ;;
      could-not-run)
        _first "$state/claims.err"
        msg="claims: could not run (exit $(_get rc '(none)')): ${FIRST:-(no stderr)}; verifier dispatched" ;;
      preflight)
        sum=""
        if [ -f "$state/claims.out" ]; then
          while IFS= read -r l; do
            case "$l" in 'claims-check: checked '*) sum="$l" ;; esac
          done < "$state/claims.out"
        fi
        msg="preflight: evidence exit $(_get evrc '(none)'); claims runs $(_get runs 0), last exit $(_get rc '(none)'); ${sum:-(none)}" ;;
      *) _usage "unknown log kind '$kind'" ;;
    esac
    _log "$msg"
    case "$kind" in
      left-as-written) rm -f -- "$issue_dir/.preflight-reason" ;;
      preflight)       rm -rf -- "$state"; rm -f -- "$issue_dir/.preflight-reason" ;;
    esac ;;
  *) _usage "unknown subcommand '$sub'" ;;
esac
