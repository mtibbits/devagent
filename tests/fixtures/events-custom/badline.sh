#!/usr/bin/env bash
# #712 bc_events_coverage fixture: separates with a space, not a TAB.
[ "${1:-}" = events ] && [ "${2:-}" = --kinds ] || exit 2
echo 'created full'
