#!/usr/bin/env bash
# tests/fixtures/watchdog/launcher.sh — #932: a model launcher. It polls
# `watchdog.sh check` for one session the way a real launcher would, except that
# its clock is virtual: each poll passes --now and then steps it by the poll
# interval, so a test covers a whole no-progress limit without waiting.
#
# usage: launcher.sh <watchdog.sh> <project> <issue> <transcript> <start epoch> <poll secs> <polls>
#
#   exit 3   check answered `stalled`; prints "stalled-at=<epoch> polls=<n>" and
#            then check's own line
#   exit 0   every poll answered ok; prints "ok-through=<epoch> polls=<n>"
#   other    check's own exit (1 cannot determine, 2 usage); prints
#            "check-rc=<rc> at=<epoch>"
set -u

watchdog="$1" project="$2" issue="$3" transcript="$4" now="$5" poll="$6" polls="$7"

i=0
while (( i < polls )); do
  i=$((i + 1))
  rc=0
  line="$(bash "$watchdog" check "$project" "$issue" --transcript "$transcript" --now "$now")" || rc=$?
  case "$rc" in
    0) ;;
    3) echo "stalled-at=$now polls=$i"
       echo "$line"
       exit 3 ;;
    *) echo "check-rc=$rc at=$now"
       exit "$rc" ;;
  esac
  now=$((now + poll))
done
echo "ok-through=$((now - poll)) polls=$i"
exit 0
