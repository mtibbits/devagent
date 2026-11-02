#!/usr/bin/env bash
# tests/fixtures/quarantine-backend/github.sh — a stateful issue-backend stub for
# the #714 quarantine tests, reached through DEVAGENT_ISSUE_BACKEND_DIR. State
# lives in $QB_DIR:
#   calls        one line per call: the verb, then its args (appended)
#   events.tsv   the bc_rec lines `events` prints; transition appends to it
#   events.rc    `events` exit code (default 0)
#   transition.rc, label.rc   `transition` / `state-exists` exit codes (0)
#   clock        the time a transition's labeled record carries
#   seq          the last seq handed out (transition takes the next one)
# QB_WHOAMI is the account id (default 1001); QB_LABEL the label name
# `transition … quarantine` writes (default devagent:quarantine).
set -u
d="${QB_DIR:?QB_DIR unset}"
printf '%s\n' "$*" >> "$d/calls"
_rc() { if [ -f "$d/$1" ]; then tr -d '\r\n' < "$d/$1"; else echo 0; fi; }
case "${1:-}" in
  whoami)
    echo "${QB_WHOAMI:-1001}" ;;
  events)
    rc="$(_rc events.rc)"
    [ "$rc" = 0 ] || exit "$rc"
    [ ! -f "$d/events.tsv" ] || cat "$d/events.tsv" ;;
  transition)
    rc="$(_rc transition.rc)"
    [ "$rc" = 0 ] || exit "$rc"
    if [ "${4:-}" = quarantine ]; then
      seq=$(( $(_rc seq) + 1 ))
      echo "$seq" > "$d/seq"
      clock="2026-11-02T10:00:00Z"
      [ ! -f "$d/clock" ] || clock="$(tr -d '\r\n' < "$d/clock")"
      printf '%s\t%s\t%s\tuser\tlabeled\tLA_q %s\n' "$clock" "$seq" "${QB_WHOAMI:-1001}" \
        "${QB_LABEL:-devagent:quarantine}" >> "$d/events.tsv"
    fi ;;
  state-exists)
    exit "$(_rc label.rc)" ;;
  *) exit 0 ;;
esac
