load 'helpers/auth_setup'

setup()    { auth_setup_common; install_stub gh ""; install_stub glab ""; install_stub curl ""; }
teardown() { auth_teardown_common; }

@test "doctor_auth check for project with no secrets reports MISSING per backend" {
  run scripts/lib/doctor_auth.sh check volk github gitlab
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: MISSING"* ]]
  [[ "${output}" == *"gitlab: MISSING"* ]]
}

@test "doctor_auth check with stored token reports OK and metadata, no token" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  run scripts/lib/doctor_auth.sh check volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: OK"* ]]
  [[ "${output}" != *"ghp_0123456789abcdef"* ]]
}

@test "doctor_auth check with stored token but bad mode reports WARN" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  chmod 644 "${DEVAGENT_SECRETS_DIR}/volk.github.pat"
  run scripts/lib/doctor_auth.sh check volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: WARN"* ]]
  [[ "${output}" == *"mode=644"* ]]
}

@test "doctor_auth check with bad secrets-dir mode reports WARN globally" {
  mkdir -p "${DEVAGENT_SECRETS_DIR}"
  chmod 755 "${DEVAGENT_SECRETS_DIR}"
  run scripts/lib/doctor_auth.sh check volk github
  [[ "${output}" == *"secrets_dir_mode=755"* ]]
  [[ "${output}" == *"WARN"* ]]
}

@test "doctor_auth check exits 0 even on failures (advisory, not gating)" {
  run scripts/lib/doctor_auth.sh check volk github gitlab jira
  [ "${status}" -eq 0 ]
}

@test "doctor_auth check supports ssh as a 'backend'" {
  run scripts/lib/doctor_auth.sh check volk ssh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ssh: MISSING"* ]]
}

@test "doctor_auth resolves a relative ssh symlink target (B13: not against CWD)" {
  mkdir -p "${DEVAGENT_SECRETS_DIR}"
  chmod 700 "${DEVAGENT_SECRETS_DIR}"
  # A real key referenced by a RELATIVE symlink target. The old `readlink`
  # returned "volk.ssh.key" and the existence check resolved it against the
  # caller's CWD (the repo root here), falsely reporting a dangling symlink.
  printf 'KEY\n' > "${DEVAGENT_SECRETS_DIR}/volk.ssh.key"
  chmod 600 "${DEVAGENT_SECRETS_DIR}/volk.ssh.key"
  ln -s volk.ssh.key "${DEVAGENT_SECRETS_DIR}/volk.ssh"
  run scripts/lib/doctor_auth.sh check volk ssh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ssh: OK"* ]]
  [[ "${output}" != *"dangling_symlink"* ]]
}
