#!/usr/bin/env bash
# scripts/lib/doctor_auth.sh
#
# Doctor hook for the auth subsystem. Phase 1's /devagent:doctor calls
# this script as:
#
#     scripts/lib/doctor_auth.sh check <project> <backend> [<backend> ...]
#
# Contract:
#   - Prints one line per backend in the form:
#         <backend>: <STATUS> [key=value ...]
#     where STATUS is one of: OK | WARN | SKIP | MISSING | ERROR
#     (SKIP = a mode check that can't apply because the filesystem does
#      not represent POSIX modes — Windows/noacl NTFS, #289.)
#   - Prints one summary line for the secrets dir:
#         secrets_dir: <STATUS> secrets_dir_mode=<octal> [...]
#   - NEVER prints the token value.
#   - Exits 0 regardless of findings (this is advisory, not gating).
#     Doctor aggregates statuses across all hooks and decides exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/secrets.sh"

_check_dir() {
  if [ ! -d "${DEVAGENT_SECRETS_DIR}" ]; then
    printf 'secrets_dir: MISSING path=%s\n' "${DEVAGENT_SECRETS_DIR}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${DEVAGENT_SECRETS_DIR}")"
  if [ "${mode}" = "700" ]; then
    printf 'secrets_dir: OK secrets_dir_mode=%s\n' "${mode}"
  elif ! posix_modes_representable "${DEVAGENT_SECRETS_DIR}"; then
    printf 'secrets_dir: SKIP secrets_dir_mode=%s reason=modes-unrepresentable\n' "${mode}"
  else
    printf 'secrets_dir: WARN secrets_dir_mode=%s expected=700\n' "${mode}"
  fi
}

_check_pat_backend() {
  local proj="$1" backend="$2"
  local f
  f="$(secret_path "${proj}" "${backend}")" || { printf '%s: ERROR invalid_name\n' "${backend}"; return; }
  if [ ! -f "${f}" ]; then
    printf '%s: MISSING path=%s\n' "${backend}" "${f}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${f}")"
  if [ "${mode}" != "600" ]; then
    # #289: a 644 read-back on noacl NTFS is not real drift — skip, don't WARN.
    if ! posix_modes_representable "$(dirname "${f}")"; then
      printf '%s: SKIP mode=%s reason=modes-unrepresentable\n' "${backend}" "${mode}"
    else
      printf '%s: WARN mode=%s expected=600\n' "${backend}" "${mode}"
    fi
    return
  fi
  local size; size="$(stat -c '%s' "${f}")"
  printf '%s: OK mode=%s size_bytes=%s\n' "${backend}" "${mode}" "${size}"
}

_check_ssh_backend() {
  local proj="$1"
  local link="${DEVAGENT_SECRETS_DIR}/${proj}.ssh"
  if [ ! -L "${link}" ]; then
    printf 'ssh: MISSING path=%s\n' "${link}"
    return
  fi
  # -f canonicalizes a relative target against the symlink's own directory; a
  # bare `readlink` returned it raw and the existence check below resolved it
  # against the caller's CWD, falsely reporting a valid key as dangling.
  local target; target="$(readlink -f "${link}")"
  if [ ! -f "${target}" ]; then
    printf 'ssh: ERROR dangling_symlink target=%s\n' "${target}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${target}")"
  if [ "${mode}" != "600" ]; then
    # #289: skip rather than WARN when the filesystem can't represent modes.
    if ! posix_modes_representable "$(dirname "${target}")"; then
      printf 'ssh: SKIP mode=%s reason=modes-unrepresentable target=%s\n' "${mode}" "${target}"
    else
      printf 'ssh: WARN mode=%s expected=600 target=%s\n' "${mode}" "${target}"
    fi
    return
  fi
  printf 'ssh: OK target=%s\n' "${target}"
}

main() {
  if [ "${1:-}" != "check" ]; then
    echo "doctor_auth: usage: $0 check <project> <backend> [<backend> ...]" >&2
    exit 1
  fi
  shift
  local proj="${1:-}"; shift || true
  if [ -z "${proj}" ]; then
    echo "doctor_auth: project required" >&2
    exit 1
  fi
  _check_dir
  local b
  for b in "$@"; do
    case "${b}" in
      ssh) _check_ssh_backend "${proj}" ;;
      *)   _check_pat_backend "${proj}" "${b}" ;;
    esac
  done
  exit 0
}

main "$@"
