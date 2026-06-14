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

# --- #91: attributable validation, fail closed -----------------------------

# Stub `gh api user -i` as a proven-invalid token: 401 status, non-zero exit.
_gh_stub_invalid() {
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 401 Unauthorized\r\n'
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
}

@test "github create fails closed on an invalid token — no secret written (#91)" {
  _gh_stub_invalid
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  run env DEVAGENT_CREATE_TOKEN_FILE="${tf}" scripts/auth/github.sh create volk
  [ "${status}" -ne 0 ]
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "github store fails closed on an invalid token — no secret written (#91)" {
  _gh_stub_invalid
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -ne 0 ]
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "github rotate fails closed on an invalid new token — old token kept (#91)" {
  # store a valid token first (setup stub is valid), then rotate to an invalid one
  local old="${BATS_TEST_TMPDIR}/old"; synthetic_token >"${old}"
  scripts/auth/github.sh store volk "${old}"
  _gh_stub_invalid
  local new="${BATS_TEST_TMPDIR}/new"
  printf 'ghp_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"${new}"
  run env DEVAGENT_ROTATE_TOKEN_FILE="${new}" scripts/auth/github.sh rotate volk
  [ "${status}" -ne 0 ]
  # the old, valid token must still be the stored one (rotate refused the swap)
  [ "$(cat "${DEVAGENT_SECRETS_DIR}/volk.github.pat")" = "$(synthetic_token)" ]
}

@test "github scopes line is not truncated at an 'n' (#95)" {
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 200 OK\r\n'
printf 'X-Oauth-Scopes: admin:org, repo, workflow\r\n'
exit 0
EOF
  chmod +x "${STUB_BIN}/gh"
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  run scripts/auth/github.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"admin:org"* ]]   # not truncated at the 'n' in admin
  [[ "${output}" == *"workflow"* ]]    # the tail of the line survives
}

@test "github stores with a warning when validation can't run (network), not refuse (#91)" {
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "error connecting to api.github.com" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -eq 0 ]                                     # stored, not refused
  [ -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
  [[ "${output}" == *"could not validate"* ]]              # but loudly warned
}

@test "github stores with a warning on a 503/429 transient, not refuse (#91 review)" {
  # A rate-limit / server error is NOT proof the token is invalid (only 401 is).
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 503 Service Unavailable\r\n'
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  [ "${status}" -eq 0 ]                                # stored, not refused
  [ -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
  [[ "${output}" == *"could not validate"* ]]
}

@test "github create masks a clipboard-sourced token, never prints it whole (#91)" {
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 200 OK\r\n'
printf 'X-Oauth-Scopes: repo, workflow\r\n'
exit 0
EOF
  chmod +x "${STUB_BIN}/gh"
  install_stub xclip "ghp_0123456789abcdef0123456789abcdef0123"
  run scripts/auth/github.sh create volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ghp_0123"* ]]                                            # masked prefix shown
  [[ "${output}" != *"ghp_0123456789abcdef0123456789abcdef0123"* ]]           # full token never shown
}
