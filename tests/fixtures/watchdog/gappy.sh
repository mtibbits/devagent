#!/usr/bin/env bash
# tests/fixtures/watchdog/gappy.sh — #932: one silent gap between two lines.
# usage: gappy.sh <log directory> <gap seconds>
# Prints "first", waits until a log in <log directory> shows it (the pump has
# carried it), stays silent for <gap seconds>, prints "second".
dir="$1" gap="$2"
echo first
end=$((SECONDS + 30))
until grep -qs '^first$' "$dir"/*.log || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
sleep "$gap"
echo second
exit 0
