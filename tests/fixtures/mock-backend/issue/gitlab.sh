#!/usr/bin/env bash
# Mock gitlab issue backend. Returns a bare iid like the real gitlab.sh create
# contract, so file.sh's per-backend URL construction (#113) can be exercised
# without a live GitLab.
set -euo pipefail

verb="${1:-}"
shift || true

case "${verb}" in
  create)
    repo="${1:?repo required}"
    title="${2:?title required}"
    body_file="${3:?body file required}"
    [[ -f "${body_file}" ]] || { echo "body file not found" >&2; exit 2; }
    : "${MOCK_RESPONSE_NUM:=4242}"
    {
      echo "verb=create"
      echo "repo=${repo}"
      echo "title=${title}"
    } >>"${MOCK_INVOCATION_LOG:-/tmp/devagent-mock.log}"
    printf '%s\n' "${MOCK_RESPONSE_NUM}"
    ;;
  *)
    echo "mock gitlab: unknown verb ${verb}" >&2
    exit 2
    ;;
esac
