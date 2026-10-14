#!/usr/bin/env bash
# Stub issue AND code backend for `wbs update` (#703 tracker phase, #704
# MR phase).
#
# Installed under a DEVAGENT_ISSUE_BACKEND_DIR as github.sh / gitlab.sh /
# jira.sh, and under a DEVAGENT_CODE_BACKEND_DIR as github.sh / gitlab.sh
# (wbs_mr_install_stub); the backend name is this copy's basename. Both
# roles append to the same backend.log. Every call appends one
# line to $WBS_STUB_ROOT/backend.log (default $TMPROOT): each argv element
# bracketed, then [DEVAGENT_PROJECT=<v>] (register Issue-593: element-
# delimited argv).
#
#   state-list <repo>
#       list file: $WBS_STUB_ROOT/state-list.<backend>.<repo, / -> _> when it
#       exists, else $WBS_STUB_ROOT/state-list.<backend>; with neither, exit
#       78 (not implemented). Cat the list file, write <list>.err (else
#       $STUB_STATE_LIST_ERR) to stderr, exit with <list>.rc (else
#       ${STUB_STATE_LIST_RC:-0}).
#   issue-mrs <repo> <id>...
#       output file: $WBS_STUB_ROOT/issue-mrs.<backend>.<repo, / -> _> when
#       it exists, else $WBS_STUB_ROOT/issue-mrs.<backend>; with neither,
#       exit 78 (not implemented). Cat it, write <file>.err to stderr, exit
#       with <file>.rc (else 0).
#   any other verb  exit 2 (unknown verb)
root="${WBS_STUB_ROOT:-${TMPROOT:?stub-backend: TMPROOT unset}}"
backend="$(basename "$0" .sh)"

line=""
for a in "$@"; do
  line+="[$a] "
done
printf '%s[DEVAGENT_PROJECT=%s]\n' "$line" "${DEVAGENT_PROJECT:-}" >> "$root/backend.log"

case "${1:-}" in
  state-list)
    repo="${2:-}"
    list="$root/state-list.$backend"
    [[ -f "$list.${repo//\//_}" ]] && list="$list.${repo//\//_}"
    [[ -f "$list" ]] || exit 78
    cat "$list"
    err="${STUB_STATE_LIST_ERR:-}"
    [[ -f "$list.err" ]] && err="$(cat "$list.err")"
    [[ -n "$err" ]] && printf '%s\n' "$err" >&2
    rc="${STUB_STATE_LIST_RC:-0}"
    [[ -f "$list.rc" ]] && rc="$(cat "$list.rc")"
    exit "$rc"
    ;;
  issue-mrs)
    repo="${2:-}"
    out="$root/issue-mrs.$backend"
    [[ -f "$out.${repo//\//_}" ]] && out="$out.${repo//\//_}"
    [[ -f "$out" ]] || exit 78
    cat "$out"
    [[ -f "$out.err" ]] && cat "$out.err" >&2
    rc=0
    [[ -f "$out.rc" ]] && rc="$(cat "$out.rc")"
    exit "$rc"
    ;;
  *) exit 2 ;;
esac
