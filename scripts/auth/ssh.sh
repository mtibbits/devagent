#!/usr/bin/env bash
# scripts/auth/ssh.sh
#
# SSH keypair lifecycle. Verbs: create, destroy, rotate, status.
# (store and exec are PAT-only concepts; not exposed for SSH.)
#
# Key naming: ~/.ssh/devagent_<project>_<utc-yyyymmddHHMMSS>_<rand>
# Symlink:    ~/.claude/devagent/secrets/<project>.ssh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/secrets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="ssh"

_ssh_link_path() {
  printf '%s/%s.ssh\n' "${DEVAGENT_SECRETS_DIR}" "$1"
}

_ssh_new_key_path() {
  local proj="$1"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"
  # Random suffix prevents collisions if rotate fires in the same second.
  local rand="${RANDOM}${RANDOM}"
  printf '%s/.ssh/devagent_%s_%s_%s\n' "${HOME}" "${proj}" "${ts}" "${rand}"
}

_ssh_create() {
  local proj="$1"
  _secret_validate_name project "${proj}" || return 1
  _secret_ensure_dir
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  local key_path; key_path="$(_ssh_new_key_path "${proj}")"
  ssh-keygen -t ed25519 -N '' -C "devagent-${proj}" -f "${key_path}" >/dev/null
  local link; link="$(_ssh_link_path "${proj}")"
  ln -sfn "${key_path}" "${link}"
  echo "auth/ssh: created ${key_path} (linked at ${link})" >&2
}

_ssh_destroy() {
  local proj="$1"
  _secret_validate_name project "${proj}" || return 1
  local link; link="$(_ssh_link_path "${proj}")"
  if [ -L "${link}" ]; then
    local target; target="$(readlink "${link}")"
    if [ -f "${target}" ]; then
      if command -v shred >/dev/null 2>&1; then
        shred -u -- "${target}" || rm -f -- "${target}"
      else
        rm -f -- "${target}"
      fi
    fi
    if [ -f "${target}.pub" ]; then
      rm -f -- "${target}.pub"
    fi
    rm -f -- "${link}"
  fi
}

_ssh_rotate() {
  local proj="$1"
  _ssh_destroy "${proj}"
  _ssh_create  "${proj}"
}

_ssh_status() {
  local proj="$1"
  local link; link="$(_ssh_link_path "${proj}")"
  if [ ! -L "${link}" ]; then
    printf 'project=%s backend=ssh present=false\n' "${proj}"
    return 0
  fi
  local target; target="$(readlink "${link}")"
  local fp="unknown"
  if [ -f "${target}.pub" ] && command -v ssh-keygen >/dev/null 2>&1; then
    fp="$(ssh-keygen -l -f "${target}.pub" 2>/dev/null | awk '{print $2}')"
    [ -n "${fp}" ] || fp="unknown"
  fi
  local agent_loaded="no"
  if command -v ssh-add >/dev/null 2>&1; then
    if ssh-add -l 2>/dev/null | grep -qF "${target}"; then
      agent_loaded="yes"
    fi
  fi
  printf 'project=%s backend=ssh present=true target=%s fingerprint=%s agent_loaded=%s\n' \
    "${proj}" "${target}" "${fp}" "${agent_loaded}"
}

main() {
  if [ "$#" -lt 1 ]; then
    echo "auth/ssh: verb required (create|destroy|rotate|status)" >&2
    exit 1
  fi
  local verb="$1"; shift
  if [ "$#" -lt 1 ]; then
    echo "auth/ssh: project required" >&2
    exit 1
  fi
  local proj="$1"; shift
  case "${verb}" in
    create)  _ssh_create  "${proj}" ;;
    destroy) _ssh_destroy "${proj}" ;;
    rotate)  _ssh_rotate  "${proj}" ;;
    status)  _ssh_status  "${proj}" ;;
    *) echo "auth/ssh: unknown verb '${verb}'" >&2; exit 1 ;;
  esac
}

main "$@"
