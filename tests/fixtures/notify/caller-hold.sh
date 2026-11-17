#!/usr/bin/env bash
# tests/fixtures/notify/caller-hold.sh <count> — #961 C3: one of two different
# callers. Sources notify.sh and appends <count> hold lines (issue, step, question),
# each detail starting "hold ". Exits with the first failing append's status.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/notify.sh" || exit 4
i=0
while [ "$i" -lt "$1" ]; do
  i=$((i + 1))
  notify_append event=hold project=toy issue=Issue-7 step=improve question=/x/STUCK "detail=hold $i" || exit $?
done
