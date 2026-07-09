#!/usr/bin/env bash
# fixture-server.sh — bats helper that starts/stops tests/fixtures/server.py.
# Exposes:
#   FIXTURE_URL          base URL (http://127.0.0.1:PORT)
#   FIXTURE_REQUEST_LOG  path to a request log file
#   fixture_start <fixture-dir>
#   fixture_stop

# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"
_fixture_pid=""

fixture_start() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "fixture_start: bad dir '$dir'" >&2
    return 2
  fi
  local port
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  FIXTURE_URL="http://127.0.0.1:${port}"
  FIXTURE_REQUEST_LOG="$(mktemp)"
  : > "$FIXTURE_REQUEST_LOG"
  python3 "${BATS_TEST_DIRNAME}/fixtures/server.py" \
    "$dir" "$port" "$FIXTURE_REQUEST_LOG" >/dev/null 2>&1 &
  _fixture_pid=$!
  local i
  for i in $(seq 1 50); do
    if curl -s -o /dev/null "${FIXTURE_URL}/__ping__" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "fixture_start: server did not come up on $FIXTURE_URL" >&2
  return 1
}

fixture_stop() {
  if [ -n "$_fixture_pid" ]; then
    kill "$_fixture_pid" 2>/dev/null || true
    # Force-kill after a short grace period; don't `wait` (the python
    # server's signal handler can race with bats' job-control teardown
    # and block indefinitely when run under `set -e`).
    ( sleep 0.5 && kill -9 "$_fixture_pid" 2>/dev/null ) &
    _fixture_pid=""
  fi
  [ -n "${FIXTURE_REQUEST_LOG:-}" ] && rm -f "$FIXTURE_REQUEST_LOG" || true
}

export -f fixture_start fixture_stop
