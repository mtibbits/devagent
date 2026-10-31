#!/usr/bin/env bash
# #712 bc_events_coverage fixture: a custom backend whose --kinds omits
# edited-body.
[ "${1:-}" = events ] && [ "${2:-}" = --kinds ] || exit 2
printf '%s\t%s\n' created full edited-title full edited-comment full commented full
