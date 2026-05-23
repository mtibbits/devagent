load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "secret_write creates dir 0700 and file 0600" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "secret_read returns the stored value" {
  source scripts/lib/secrets.sh
  local tok; tok="$(synthetic_token)"
  secret_write volk github "${tok}"
  run secret_read volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tok}" ]
}

@test "secret_read on missing key exits 2 with empty stdout" {
  source scripts/lib/secrets.sh
  run secret_read volk github
  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
}

@test "secret_destroy shreds and unlinks" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  local f="${DEVAGENT_SECRETS_DIR}/volk.github.pat"
  [ -f "${f}" ]
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
  [ ! -e "${f}" ]
}

@test "secret_destroy on missing key exits 0 (idempotent)" {
  source scripts/lib/secrets.sh
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
}

@test "secret_stat reports backend, mtime, size; never the value" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  run secret_stat volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=github"* ]]
  [[ "${output}" == *"project=volk"* ]]
  [[ "${output}" == *"size_bytes="* ]]
  [[ "${output}" == *"mtime="* ]]
  [[ "${output}" != *"ghp_0123456789abcdef"* ]]
}

@test "secret_path returns the canonical PAT path" {
  source scripts/lib/secrets.sh
  run secret_path volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "secret_write rejects empty project name" {
  source scripts/lib/secrets.sh
  run secret_write "" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects empty backend name" {
  source scripts/lib/secrets.sh
  run secret_write volk "" "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects project names with slashes" {
  source scripts/lib/secrets.sh
  run secret_write "vo/lk" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_backend defaults to 'file' and respects override" {
  source scripts/lib/secrets.sh
  run secret_backend
  [ "${output}" = "file" ]
  DEVAGENT_SECRETS_BACKEND=keyring run secret_backend
  [ "${output}" = "keyring" ]
}

@test "keyring backend is not implemented in v1 and errors clearly" {
  source scripts/lib/secrets.sh
  DEVAGENT_SECRETS_BACKEND=keyring run secret_write volk github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"keyring backend not implemented"* ]]
}
