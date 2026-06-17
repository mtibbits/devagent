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

@test "ssh rotate replaces the key with a new filename and retires the old (#93)" {
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

@test "ssh rotate failure leaves the old key intact (#93)" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local old_target; old_target="$(readlink "${link}")"
  # Make ssh-keygen fail so the new key can't be created.
  cat >"${STUB_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_BIN}/ssh-keygen"
  run scripts/auth/ssh.sh rotate volk
  [ "${status}" -ne 0 ]
  # Old key + link must survive — the project is never left key-less.
  [ -L "${link}" ]
  [ "$(readlink "${link}")" = "${old_target}" ]
  [ -f "${old_target}" ]
}

@test "ssh create over an existing key shreds the old one — no orphan (#93)" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local old_target; old_target="$(readlink "${link}")"
  scripts/auth/ssh.sh create volk
  local new_target; new_target="$(readlink "${link}")"
  [ "${new_target}" != "${old_target}" ]
  [ ! -e "${old_target}" ]       # old private key shredded, not orphaned
  [ ! -e "${old_target}.pub" ]
  [ -f "${new_target}" ]
}

@test "ssh destroy removes the key from the agent via ssh-add -d (#93)" {
  scripts/auth/ssh.sh create volk
  : > "${STUB_LOG}"              # only capture destroy's agent calls
  run scripts/auth/ssh.sh destroy volk
  [ "${status}" -eq 0 ]
  grep -q 'ssh-add -d' "${STUB_LOG}"
}
