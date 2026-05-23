load 'helpers/auth_setup'

setup() {
  auth_setup_common
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  cat >"${STUB_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"${STUB_LOG}"
out=""
fp_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f) out="$2"; shift 2 ;;
    -l) fp_mode=1; shift ;;
    *)  shift ;;
  esac
done
if [ "${fp_mode}" = "1" ]; then
  printf '256 SHA256:abcdef0123456789FAKE devagent@host (ED25519)\n'
  exit 0
fi
if [ -n "${out}" ]; then
  printf 'fake-private-key\n' >"${out}"
  printf 'ssh-ed25519 AAAAFAKEPUBKEY devagent@host\n' >"${out}.pub"
  chmod 600 "${out}"
  chmod 644 "${out}.pub"
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/ssh-keygen"
  install_stub ssh-add ""
}
teardown() { auth_teardown_common; }

@test "ssh create generates ed25519 keypair and stores symlink" {
  run scripts/auth/ssh.sh create volk
  [ "${status}" -eq 0 ]
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  [ -L "${link}" ]
  local target; target="$(readlink "${link}")"
  [ -f "${target}" ]
  [ -f "${target}.pub" ]
  assert_mode "${target}" 600
}

@test "ssh status prints fingerprint and never the private key" {
  scripts/auth/ssh.sh create volk
  run scripts/auth/ssh.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=ssh"* ]]
  [[ "${output}" == *"fingerprint=SHA256:abcdef0123456789FAKE"* ]]
  [[ "${output}" != *"fake-private-key"* ]]
}

@test "ssh destroy shreds private key and removes symlink" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local target; target="$(readlink "${link}")"
  run scripts/auth/ssh.sh destroy volk
  [ "${status}" -eq 0 ]
  [ ! -e "${link}" ]
  [ ! -e "${target}" ]
  [ ! -e "${target}.pub" ]
}

@test "ssh rotate destroys old then creates new with different filename" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local old_target; old_target="$(readlink "${link}")"
  run scripts/auth/ssh.sh rotate volk
  [ "${status}" -eq 0 ]
  local new_target; new_target="$(readlink "${link}")"
  [ "${new_target}" != "${old_target}" ]
  [ -f "${new_target}" ]
  [ ! -e "${old_target}" ]
}

@test "ssh status with no key says present=false" {
  run scripts/auth/ssh.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"present=false"* ]]
}
