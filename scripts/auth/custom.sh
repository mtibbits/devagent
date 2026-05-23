#!/usr/bin/env bash
# scripts/auth/custom.sh
# Stub backend. Verb contract identical to the others so callers can
# select 'custom' in config.toml without breaking dispatch, but every
# verb except `status` exits 64 (EX_USAGE) with a pointer to the README.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="custom"

_not_implemented() {
  local verb="$1"
  cat >&2 <<EOF
auth/custom: '${verb}' is not implemented for the custom backend in v1.

The custom backend exists so config.toml can select it without breaking
dispatch, but it ships as stubs. See the devAgent README section
'Implementing a custom auth backend' for the verb contract you must
satisfy in your own copy of scripts/auth/custom.sh.
EOF
  exit 64
}

_status() {
  local proj="$1"
  printf 'project=%s backend=%s present=false notes=stub-backend\n' "${proj}" "${BACKEND}"
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    status)  _status "${AUTH_PROJECT}" ;;
    *)       _not_implemented "${AUTH_VERB}" ;;
  esac
}

main "$@"
