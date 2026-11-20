#!/usr/bin/env bash
# tests/fixtures/notify/caller-notice.sh <count> — #961 C3: the other caller.
# Sources notify.sh and appends <count> capture notices, each detail starting
# "notice ". Exits with the first failing append's status.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/notify.sh" || exit 4
i=0
while [ "$i" -lt "$1" ]; do
  i=$((i + 1))
  notify_append event=notify project=volk capture=2026-11-09-some-capture "detail=notice $i" || exit $?
done
