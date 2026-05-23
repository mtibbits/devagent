load 'helpers/auth_setup'

setup() {
  auth_setup_common
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${STUB_LOG}"
case "$1 $2" in
  "auth status"|"api user")
    printf 'X-Oauth-Scopes: repo, workflow, read:org\n'
    exit 0
    ;;
  "api -H Accept:")
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/gh"
  install_stub xdg-open ""
  install_stub open ""
}
teardown() { auth_teardown_common; }

@test "github store ingests a token from file and sets mode 600" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -eq 0 ]
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "github store strips trailing newlines" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ghp_0123456789abcdef0123456789abcdef0123\n\n\n' >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -eq 0 ]
  local stored
  stored="$(cat "${DEVAGENT_SECRETS_DIR}/volk.github.pat")"
  [ "${stored}" = "ghp_0123456789abcdef0123456789abcdef0123" ]
}

@test "github store rejects empty file" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  : >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -ne 0 ]
}

@test "github status with no token says present=false" {
  run scripts/auth/github.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"present=false"* ]]
}

@test "github status with token prints scopes from gh, never the token" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  run scripts/auth/github.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=github"* ]]
  [[ "${output}" == *"scopes=repo, workflow, read:org"* ]]
  [[ "${output}" != *"ghp_0123456789abcdef"* ]]
}

@test "github destroy removes the token file" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  [ -f "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
  run scripts/auth/github.sh destroy volk
  [ "${status}" -eq 0 ]
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "github rotate is atomic: new replaces old, then old destroyed" {
  local tf1="${BATS_TEST_TMPDIR}/tok1"
  local tf2="${BATS_TEST_TMPDIR}/tok2"
  printf 'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"${tf1}"
  printf 'ghp_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"${tf2}"
  scripts/auth/github.sh store volk "${tf1}"
  run env DEVAGENT_ROTATE_TOKEN_FILE="${tf2}" scripts/auth/github.sh rotate volk
  [ "${status}" -eq 0 ]
  local stored
  stored="$(cat "${DEVAGENT_SECRETS_DIR}/volk.github.pat")"
  [ "${stored}" = "ghp_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
  run ls "${DEVAGENT_SECRETS_DIR}"
  [[ "${output}" != *".old"* ]]
  [[ "${output}" != *".tmp"* ]]
}

@test "github exec sets GH_TOKEN and execs given command" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  run scripts/auth/github.sh exec volk -- env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GH_TOKEN=ghp_0123456789abcdef"* ]]
}

@test "github exec returns 2 when no token stored" {
  run scripts/auth/github.sh exec volk -- env
  [ "${status}" -eq 2 ]
}
