#!/usr/bin/env bash
# Stub for scripts/lib/log.sh (Plan 1). Real impl prepends timestamps
# and routes to stderr; the stub does the minimum needed for tests.
devagent_log() {
  local level="$1"; shift
  printf '[%s] %s\n' "$level" "$*" >&2
}
export -f devagent_log
