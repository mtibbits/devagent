#!/usr/bin/env bash
# scripts/auth/gitlab.sh
# Same verb contract as github.sh; uses glab for scope validation,
# GITLAB_TOKEN env var for exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="gitlab"
readonly ENV_VAR="GITLAB_TOKEN"
readonly PAT_URL="https://gitlab.com/-/profile/personal_access_tokens?name=devAgent&scopes=api,read_repository,write_repository"

_gl_validate_scopes() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "auth/gitlab: glab CLI not installed; skipping scope validation" >&2
    return 0
  fi
  GITLAB_TOKEN="$1" glab auth status 2>&1 \
    | grep -oE 'Token scopes:[^\n]*' | head -n1 || true
}

_gl_strip_token_file() {
  local f="$1"
  [ -f "${f}" ] || { echo "auth/gitlab: token file not found: ${f}" >&2; return 1; }
  local val
  val="$(cat "${f}")"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]] || [[ "${val}" == *$'\t' ]]; do
    val="${val%$'\n'}"; val="${val%$'\r'}"; val="${val%$'\t'}"; val="${val% }"
  done
  [ -n "${val}" ] || { echo "auth/gitlab: token file empty" >&2; return 1; }
  printf '%s' "${val}"
}

_gl_create_interactive() {
  local proj="$1"
  echo "auth/gitlab: opening browser to ${PAT_URL}" >&2
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "${PAT_URL}" >/dev/null 2>&1 || true
  elif command -v open     >/dev/null 2>&1; then open      "${PAT_URL}" >/dev/null 2>&1 || true
  fi
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gl_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip   >/dev/null 2>&1; then token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token; printf '\n' >&2
  fi
  [ -n "${token}" ] || { echo "auth/gitlab: no token provided" >&2; return 1; }
  local scopes; scopes="$(_gl_validate_scopes "${token}")"
  if [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'api'; then
    echo "auth/gitlab: token missing required scope 'api': ${scopes}" >&2
    return 1
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/gitlab: stored token for ${proj} (${scopes:-scopes unknown})" >&2
}

_gl_store() {
  local proj="$1" tokfile="$2"
  local val; val="$(_gl_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_gl_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _gl_create_interactive "${proj}"
    return 0
  fi
  local new_val; new_val="$(_gl_strip_token_file "${new_file}")"
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_gl_status() {
  local proj="$1"
  local meta; meta="$(secret_stat "${proj}" "${BACKEND}")"
  meta="${meta%$'\n'}"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then printf '\n'; return 0; fi
  local tok; tok="$(secret_read "${proj}" "${BACKEND}")"
  local scopes; scopes="$(_gl_validate_scopes "${tok}")"
  unset tok
  if [ -n "${scopes}" ]; then
    scopes="$(printf '%s' "${scopes}" | sed -e 's/^Token scopes: *//' -e "s/'//g")"
    printf ' scopes=%s' "${scopes}"
  fi
  printf ' last_used=unknown\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _gl_create_interactive "${AUTH_PROJECT}" ;;
    store)   _gl_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _gl_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _gl_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
