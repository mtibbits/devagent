#!/usr/bin/env bash
# tests/fixtures/watchdog/hold.sh — #932: a command a test can hold open.
# usage: hold.sh [--quiet] <go file>...
# Prints "up", then for each <go file> in turn waits until it exists and prints
# "after <its name>". With --quiet it prints nothing at all. Each wait gives up
# after 60 s, so a failed test leaves no process behind for long.
quiet=0
if [ "${1:-}" = --quiet ]; then quiet=1; shift; fi
[ "$quiet" = 1 ] || echo up
for go in "$@"; do
  end=$((SECONDS + 60))
  until [ -e "$go" ] || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
  [ "$quiet" = 1 ] || echo "after ${go##*/}"
done
exit 0
