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
# is read from the pinned commit's tree. It makes no network call and runs no backend:
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
# with 1, which here would read as a failed check.
# shellcheck disable=SC2317  # invoked by the EXIT trap
_on_exit() {
  local rc=$?
  printf 'preship-deferred: could not run (exited %s before the check was complete)\n' "$rc" >&2
  _exit 2
}
trap _on_exit EXIT

config_load
config_is_project "$project" || _cnr "unknown project '$project'"
# The marker check exits 11 by itself; the trap must not turn that into 2.
trap - EXIT
quarantine_guard_marker "preship-deferred" "$project" "$issue"
trap _on_exit EXIT

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

# _need_pin: sets PIN (the pinned head, a full commit id) and TREE (the issue tree).
# Whether PIN is a commit there is the reader's to say: selfcert_paths and _blob_at
# each name the commit they could not read.
_need_pin() {
  PIN="$(_state preship_pin_head)"
  [ -n "$PIN" ] || _cnr "no pinned head is recorded for $issue (preship_pin_head); the preship wrapper pins the head before it dispatches the verifier"
  [[ "$PIN" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || _cnr "preship_pin_head '${PIN//[[:cntrl:]]/?}' is not a full commit id"
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

_cnr "$sub is not implemented yet"
