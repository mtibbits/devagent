#!/usr/bin/env bash
# scripts/auth/jira.sh
# Same verb contract. Uses curl + Atlassian REST v3 /myself for
# validation. JIRA_TOKEN is the env var passed to exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="jira"
readonly ENV_VAR="JIRA_TOKEN"

_ji_strip_token_file() {
  local f="$1"
  [ -f "${f}" ] || { echo "auth/jira: token file not found: ${f}" >&2; return 1; }
  local val; val="$(cat "${f}")"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]] || [[ "${val}" == *$'\t' ]]; do
    val="${val%$'\n'}"; val="${val%$'\r'}"; val="${val%$'\t'}"; val="${val% }"
  done
  [ -n "${val}" ] || { echo "auth/jira: token file empty" >&2; return 1; }
  printf '%s' "${val}"
}

_ji_validate() {
  local tok="$1"
  if [ -z "${DEVAGENT_JIRA_BASE_URL:-}" ]; then
    printf 'validation_skipped=DEVAGENT_JIRA_BASE_URL_unset'
    return 0
  fi
  if [ -z "${DEVAGENT_JIRA_EMAIL:-}" ]; then
    printf 'validation_skipped=DEVAGENT_JIRA_EMAIL_unset'
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    printf 'validation_skipped=curl_missing'
    return 0
  fi
  local resp
  resp="$(curl -sS -u "${DEVAGENT_JIRA_EMAIL}:${tok}" \
    -H 'Accept: application/json' \
    "${DEVAGENT_JIRA_BASE_URL}/rest/api/3/myself" || true)"
  local id
  id="$(printf '%s' "${resp}" | sed -n 's/.*"accountId":"\([^"]*\)".*/\1/p')"
  if [ -n "${id}" ]; then
    printf 'accountId=%s' "${id}"
  fi
}

_ji_create_interactive() {
  local proj="$1"
  local url="https://id.atlassian.com/manage-profile/security/api-tokens"
  echo "auth/jira: opening browser to ${url}" >&2
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "${url}" >/dev/null 2>&1 || true
  elif command -v open     >/dev/null 2>&1; then open      "${url}" >/dev/null 2>&1 || true
  fi
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_ji_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip   >/dev/null 2>&1; then token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token; printf '\n' >&2
  fi
  [ -n "${token}" ] || { echo "auth/jira: no token provided" >&2; return 1; }
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/jira: stored token for ${proj}" >&2
}

_ji_store() {
  local proj="$1" tokfile="$2"
  local val; val="$(_ji_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_ji_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _ji_create_interactive "${proj}"
    return 0
  fi
  local new_val; new_val="$(_ji_strip_token_file "${new_file}")"
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_ji_status() {
  local proj="$1"
  local meta; meta="$(secret_stat "${proj}" "${BACKEND}")"
  meta="${meta%$'\n'}"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then printf '\n'; return 0; fi
  local tok; tok="$(secret_read "${proj}" "${BACKEND}")"
  local v; v="$(_ji_validate "${tok}")"
  unset tok
  if [ -n "${v}" ]; then printf ' %s' "${v}"; fi
  printf ' last_used=unknown\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _ji_create_interactive "${AUTH_PROJECT}" ;;
    store)   _ji_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _ji_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _ji_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
