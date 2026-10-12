#!/usr/bin/env bash
# Stub issue backend for the `wbs update` tracker phase (#703).
#
# Installed under a DEVAGENT_ISSUE_BACKEND_DIR as github.sh / gitlab.sh /
# jira.sh; the backend name is this copy's basename. Every call appends one
# line to $WBS_STUB_ROOT/backend.log (default $TMPROOT): each argv element
# bracketed, then [DEVAGENT_PROJECT=<v>] (register Issue-593: element-
# delimited argv).
#
#   state-list  cat $WBS_STUB_ROOT/state-list.<backend> when it exists, write
#               $STUB_STATE_LIST_ERR to stderr, exit ${STUB_STATE_LIST_RC:-0};
#               with no list file, exit 78 (not implemented)
#   any other   exit 2 (unknown verb)
root="${WBS_STUB_ROOT:-${TMPROOT:?stub-backend: TMPROOT unset}}"
backend="$(basename "$0" .sh)"

line=""
for a in "$@"; do
  line+="[$a] "
done
printf '%s[DEVAGENT_PROJECT=%s]\n' "$line" "${DEVAGENT_PROJECT:-}" >> "$root/backend.log"

case "${1:-}" in
  state-list)
    list="$root/state-list.$backend"
    [[ -f "$list" ]] || exit 78
    cat "$list"
    [[ -n "${STUB_STATE_LIST_ERR:-}" ]] && printf '%s\n' "$STUB_STATE_LIST_ERR" >&2
    exit "${STUB_STATE_LIST_RC:-0}"
    ;;
  *) exit 2 ;;
esac
