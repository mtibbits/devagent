#!/usr/bin/env bash
# Mock github issue backend. Records invocations so tests can assert.
set -euo pipefail

verb="${1:-}"
shift || true

case "${verb}" in
  create)
    repo="${1:?repo required}"
    title="${2:?title required}"
    body_file="${3:?body file required}"
    [[ -f "${body_file}" ]] || { echo "body file not found" >&2; exit 2; }
    # Test hook (#113): simulate a create that fails after being invoked.
    [[ "${MOCK_FORCE_FAIL:-0}" = "1" ]] && { echo "mock: forced create failure" >&2; exit 1; }
    : "${MOCK_RESPONSE_NUM:=4242}"
    # Record for assertions.
    {
      echo "verb=create"
      echo "repo=${repo}"
      echo "title=${title}"
      echo "body_file=${body_file}"
      printf 'body=<<<\n'
      cat "${body_file}"
      printf '>>>\n'
    } >>"${MOCK_INVOCATION_LOG:-/tmp/devagent-mock.log}"
    printf '%s\n' "${MOCK_RESPONSE_NUM}"
    ;;
  *)
    echo "mock github: unknown verb ${verb}" >&2
    exit 2
    ;;
esac
