#!/usr/bin/env bash
# tests/fixtures/watchdog/chunks.sh — #932: three separate chunks of output.
# usage: chunks.sh <log directory>
# After each line it waits until a log in <log directory> shows that line, so
# the wrapper's pump has carried it before the next one is written: three
# lines are three reads, on any host. Each wait gives up after 30 s.
dir="$1"
for i in 1 2 3; do
  echo "chunk $i"
  end=$((SECONDS + 30))
  until grep -qs "^chunk $i\$" "$dir"/*.log || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
done
exit 0
