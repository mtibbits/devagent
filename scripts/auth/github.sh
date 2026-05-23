#!/usr/bin/env bash
# scripts/auth/github.sh
#
# GitHub PAT lifecycle.
#
# Verbs:
#   create   <project>           — interactive: open browser, paste, validate, store
#   store    <project> <file>    — non-interactive ingest
#   rotate   <project>           — atomic create-new, swap, destroy-old
#                                  (in non-interactive mode, reads
#                                   $DEVAGENT_ROTATE_TOKEN_FILE)
#   destroy  <project>           — shred + unlink
#   status   <project>           — backend, scopes, expiry, last-used (never the token)
#   exec     <project> -- cmd... — set GH_TOKEN, exec cmd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="github"
readonly ENV_VAR="GH_TOKEN"
readonly PAT_URL="https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=devAgent"

_gh_validate_scopes() {
  # Returns a "Header: scope, scope" line from gh's output, or empty.
  # Accepts both "Token scopes: ..." (interactive `gh auth status`)
  # and "X-Oauth-Scopes: ..." (API response headers).
  if ! command -v gh >/dev/null 2>&1; then
    echo "auth/github: gh CLI not installed; skipping scope validation" >&2
    return 0
  fi
  local out
  out="$(GH_TOKEN="$1" gh auth status 2>&1 || true)"
  printf '%s\n' "${out}" \
    | grep -oE '(Token scopes:|X-Oauth-Scopes:)[^\n]*' \
    | head -n1 || true
}

_gh_strip_token_file() {
  local f="$1"
  if [ ! -f "${f}" ]; then
    echo "auth/github: token file not found: ${f}" >&2
    return 1
  fi
  local val
  val="$(cat "${f}")"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]] || [[ "${val}" == *$'\t' ]]; do
    val="${val%$'\n'}"
    val="${val%$'\r'}"
    val="${val%$'\t'}"
    val="${val% }"
  done
  if [ -z "${val}" ]; then
    echo "auth/github: token file is empty: ${f}" >&2
    return 1
  fi
  printf '%s' "${val}"
}

_gh_create_interactive() {
  local proj="$1"
  echo "auth/github: opening browser to ${PAT_URL}" >&2
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${PAT_URL}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${PAT_URL}" >/dev/null 2>&1 || true
  fi
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gh_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip >/dev/null 2>&1; then
    token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then
    token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token
    printf '\n' >&2
  fi
  if [ -z "${token}" ]; then
    echo "auth/github: no token provided" >&2
    return 1
  fi
  local scopes
  scopes="$(_gh_validate_scopes "${token}")"
  if [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'repo'; then
    echo "auth/github: token missing required scope 'repo': ${scopes}" >&2
    return 1
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/github: stored token for ${proj} (${scopes:-scopes unknown})" >&2
}

_gh_store() {
  local proj="$1" tokfile="$2"
  local val
  val="$(_gh_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_gh_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _gh_create_interactive "${proj}"
    return 0
  fi
  local new_val
  new_val="$(_gh_strip_token_file "${new_file}")"
  # secret_write is itself atomic (mktemp+mv), so this IS the swap.
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_gh_status() {
  local proj="$1"
  local meta
  meta="$(secret_stat "${proj}" "${BACKEND}")"
  # secret_stat already prints "backend=github..."; trim its newline
  # so we can append scopes= on the same line.
  meta="${meta%$'\n'}"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then
    printf '\n'
    return 0
  fi
  local tok scopes
  tok="$(secret_read "${proj}" "${BACKEND}")"
  scopes="$(_gh_validate_scopes "${tok}")"
  unset tok
  if [ -n "${scopes}" ]; then
    scopes="$(printf '%s' "${scopes}" \
      | sed -e 's/^Token scopes: *//' \
            -e 's/^X-Oauth-Scopes: *//' \
            -e "s/'//g")"
    printf ' scopes=%s' "${scopes}"
  fi
  printf ' last_used=unknown\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _gh_create_interactive "${AUTH_PROJECT}" ;;
    store)   _gh_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _gh_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _gh_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
