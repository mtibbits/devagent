#!/usr/bin/env bash
# tests/fixtures/watchdog/interleave.sh — #932: forty lines on stdout
# interleaved with forty on stderr, then exit 3. A caller that merges the two
# (2>&1) sees one fixed order, which a wrapper in the data path must keep.
for i in $(seq 1 40); do
  echo "out $i"
  echo "err $i" >&2
done
exit 3
