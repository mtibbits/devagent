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

_gl_validate_token() {
  # Attributable validation via `glab api user` (#91); same 0/1/2 three-state
  # contract as github (0=valid / 1=proven-bad → fail closed / 2=can't tell).
  # Unlike `glab auth status` it never borrows the keyring login's scopes.
  # Scopes (best-effort, GitLab >=16) from personal_access_tokens/self.
  # #95: scopes joined by glab's jq, not the truncating `[^\n]` grep.
  command -v glab >/dev/null 2>&1 || return 2
  local out
  if out="$(GITLAB_TOKEN="$1" glab api user -i 2>&1)"; then
    GITLAB_TOKEN="$1" glab api personal_access_tokens/self \
        --jq '.scopes | join(", ")' 2>/dev/null | tr -d '\r' | head -n1 || true
    return 0
  fi
  printf '%s\n' "${out}" | grep -qiE 'HTTP/[0-9.]+ [45][0-9][0-9]' && return 1
  return 2
}

_gl_validate_and_store() {
  local proj="$1" token="$2"
  local scopes rc
  scopes="$(_gl_validate_token "${token}")" && rc=0 || rc=$?
  if [ "${rc}" -eq 1 ]; then
    echo "auth/gitlab: token rejected — GitLab reports it is invalid; not stored (#91)" >&2
    return 1
  fi
  if [ "${rc}" -eq 0 ] && [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'api'; then
    echo "auth/gitlab: token missing required scope 'api': ${scopes}" >&2
    return 1
  fi
  if [ "${rc}" -eq 2 ]; then
    echo "auth/gitlab: could not validate token (glab unavailable or network error); storing anyway" >&2
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/gitlab: stored token for ${proj} (${scopes:-scopes unknown})" >&2
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
  local token="" from_clipboard=0
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gl_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip   >/dev/null 2>&1; then token="$(xclip -selection clipboard -o 2>/dev/null || true)"; from_clipboard=1
  elif command -v pbpaste >/dev/null 2>&1; then token="$(pbpaste 2>/dev/null || true)"; from_clipboard=1
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token; printf '\n' >&2
    from_clipboard=0
  fi
  [ -n "${token}" ] || { echo "auth/gitlab: no token provided" >&2; return 1; }
  if [ "${from_clipboard}" -eq 1 ]; then
    # Masked-prefix confirmation for the silent clipboard grab, never the whole secret (#91).
    echo "auth/gitlab: using clipboard token ${token:0:8}… (${#token} chars)" >&2
  fi
  _gl_validate_and_store "${proj}" "${token}"
}

_gl_store() {
  local proj="$1" tokfile="$2"
  local val; val="$(_gl_strip_token_file "${tokfile}")"
  _gl_validate_and_store "${proj}" "${val}"   # #91: validate + fail closed
}

_gl_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _gl_create_interactive "${proj}"
    return            # propagate create's exit (fail-closed on a bad new token)
  fi
  local new_val; new_val="$(_gl_strip_token_file "${new_file}")"
  _gl_validate_and_store "${proj}" "${new_val}"   # #91: a proven-bad new token leaves the old in place
}

_gl_status() {
  local proj="$1"
  local meta; meta="$(secret_stat "${proj}" "${BACKEND}")"
  meta="${meta%$'\n'}"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then printf '\n'; return 0; fi
  local tok; tok="$(secret_read "${proj}" "${BACKEND}")"
  # informational: tolerate proven-bad (rc 1) / can't-determine (rc 2) (#91)
  local scopes; scopes="$(_gl_validate_token "${tok}")" || true
  unset tok
  if [ -n "${scopes}" ]; then
    scopes="$(printf '%s' "${scopes}" | sed -e "s/'//g")"
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
