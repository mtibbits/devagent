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

# #93(c): drop the key from a running ssh-agent so a loaded agent stops
# authenticating with it. Best-effort: no agent / not loaded / no ssh-add are all
# fine. ssh-add -d removes by public key.
_ssh_forget_agent() {
  local target="$1"
  command -v ssh-add >/dev/null 2>&1 || return 0
  if [ -f "${target}.pub" ]; then
    ssh-add -d "${target}.pub" >/dev/null 2>&1 || true
  else
    ssh-add -d "${target}" >/dev/null 2>&1 || true
  fi
  return 0
}

# Retire a key target: forget it from the agent, shred the private key, remove
# the pubkey. Used by destroy and by create's old-key cleanup.
_ssh_shred_key() {
  local target="$1"
  [ -n "${target}" ] || return 0
  _ssh_forget_agent "${target}"
  if [ -f "${target}" ]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u -- "${target}" || rm -f -- "${target}"
    else
      rm -f -- "${target}"
    fi
  fi
  [ -f "${target}.pub" ] && rm -f -- "${target}.pub"
  return 0
}

_ssh_create() {
  local proj="$1"
  _secret_validate_name project "${proj}" || return 1
  _secret_ensure_dir
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  local link; link="$(_ssh_link_path "${proj}")"
  # #93(a,b): capture the existing key BEFORE creating the new one, so we can
  # retire it only AFTER the new key is live + linked (create-new → repoint →
  # shred-old). ssh-keygen failure aborts here under set -e, leaving the old key
  # and link untouched — the project is never left key-less.
  local old_target=""
  [ -L "${link}" ] && old_target="$(readlink "${link}")"
  local key_path; key_path="$(_ssh_new_key_path "${proj}")"
  ssh-keygen -t ed25519 -N '' -C "devagent-${proj}" -f "${key_path}" >/dev/null
  ln -sfn "${key_path}" "${link}"
  # New key is live; now retire the previous one (no orphan in ~/.ssh).
  if [ -n "${old_target}" ] && [ "${old_target}" != "${key_path}" ]; then
    _ssh_shred_key "${old_target}"
  fi
  echo "auth/ssh: created ${key_path} (linked at ${link})" >&2
}

_ssh_destroy() {
  local proj="$1"
  _secret_validate_name project "${proj}" || return 1
  local link; link="$(_ssh_link_path "${proj}")"
  if [ -L "${link}" ]; then
    local target; target="$(readlink "${link}")"
    _ssh_shred_key "${target}"
    rm -f -- "${link}"
  fi
}

_ssh_rotate() {
  # #93(a): create now does create-new → repoint → shred-old with a real overlap
  # window (ssh-keygen failure aborts before the old key is touched), so rotate is
  # exactly create.
  _ssh_create "$1"
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
