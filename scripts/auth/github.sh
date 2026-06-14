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

_gh_validate_token() {
  # Validate <token> ATTRIBUTABLY via `gh api user` (#91). Prints the token's
  # scopes on stdout when known. Exit codes (the repo's #85/#154 three-state):
  #   0 = valid       — HTTP 2xx for THIS token.
  #   1 = proven bad  — HTTP 401 (bad credentials) for THIS token; FAIL CLOSED.
  #   2 = can't tell  — gh absent / network / 403 / 429 / 5xx / no status; warn.
  # Only 401 is "proven bad": on the /user endpoint a valid token is 200, an
  # invalid/revoked one is 401, and 403/429 are rate-limit (valid-but-throttled)
  # — rejecting those would refuse a good token during an outage.
  # Unlike the old `gh auth status`, `gh api user` never falls back to the
  # keyring login, so an invalid candidate can no longer borrow another
  # account's scopes as false confirmation.
  # #95: scopes parsed with `.*$` (the old `[^\n]` truncated the line at 'n').
  command -v gh >/dev/null 2>&1 || return 2
  local out
  if out="$(GH_TOKEN="$1" gh api user -i 2>&1)"; then
    printf '%s\n' "${out}" | tr -d '\r' \
      | grep -ioE 'x-oauth-scopes:.*$' | head -n1 \
      | sed -E 's/^[Xx]-[Oo]auth-[Ss]copes:[[:space:]]*//' || true
    return 0
  fi
  printf '%s\n' "${out}" | grep -qiE 'HTTP/[0-9.]+ 401([^0-9]|$)' && return 1
  return 2
}

_gh_validate_and_store() {
  # Shared gate for create/store/rotate: validate, fail closed on a proven-bad
  # token, warn-but-store when validation can't run, then persist.
  local proj="$1" token="$2"
  local scopes rc
  scopes="$(_gh_validate_token "${token}")" && rc=0 || rc=$?
  if [ "${rc}" -eq 1 ]; then
    echo "auth/github: token rejected — GitHub reports it is invalid; not stored (#91)" >&2
    return 1
  fi
  if [ "${rc}" -eq 0 ] && [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'repo'; then
    echo "auth/github: token missing required scope 'repo': ${scopes}" >&2
    return 1
  fi
  if [ "${rc}" -eq 2 ]; then
    echo "auth/github: could not validate token (gh unavailable, network error, rate limit, or server error); storing anyway" >&2
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/github: stored token for ${proj} (${scopes:-scopes unknown})" >&2
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
  local token="" from_clipboard=0
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gh_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip >/dev/null 2>&1; then
    token="$(xclip -selection clipboard -o 2>/dev/null || true)"; from_clipboard=1
  elif command -v pbpaste >/dev/null 2>&1; then
    token="$(pbpaste 2>/dev/null || true)"; from_clipboard=1
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token
    printf '\n' >&2
    from_clipboard=0
  fi
  if [ -z "${token}" ]; then
    echo "auth/github: no token provided" >&2
    return 1
  fi
  if [ "${from_clipboard}" -eq 1 ]; then
    # The clipboard grab is silent and may not be the token you intend — show a
    # masked prefix for confirmation, never the whole secret (#91).
    echo "auth/github: using clipboard token ${token:0:8}… (${#token} chars)" >&2
  fi
  _gh_validate_and_store "${proj}" "${token}"
}

_gh_store() {
  local proj="$1" tokfile="$2"
  local val
  val="$(_gh_strip_token_file "${tokfile}")"
  # #91: store now validates and fails closed, like create.
  _gh_validate_and_store "${proj}" "${val}"
}

_gh_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _gh_create_interactive "${proj}"
    return            # propagate create's exit (fail-closed if the new token is bad)
  fi
  local new_val
  new_val="$(_gh_strip_token_file "${new_file}")"
  # #91: validate the NEW token before the swap; a proven-bad token leaves the
  # existing one in place (_gh_validate_and_store does not write on rc 1).
  # secret_write is itself atomic (mktemp+mv), so this IS the swap.
  _gh_validate_and_store "${proj}" "${new_val}"
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
  # status is informational: tolerate a proven-bad (rc 1) or can't-determine
  # (rc 2) stored token — report scopes if known, never fail status (#91).
  scopes="$(_gh_validate_token "${tok}")" || true
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
    create)  _gh_create_interactive "${AUTH_PROJECT}" ;;
    store)   _gh_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _gh_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _gh_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
