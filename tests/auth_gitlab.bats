load 'helpers/auth_setup'

setup() {
  auth_setup_common
  cat >"${STUB_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >>"${STUB_LOG}"
case "$1 $2" in
  "api user")                              # attributable validity probe (#91): 2xx
    exit 0
    ;;
  "api personal_access_tokens/self")       # scopes readout (already --jq joined)
    printf 'api, read_repository, write_repository\n'
    exit 0
    ;;
  "auth status")                           # legacy path (pre-#91), kept harmless
    printf 'Token scopes: api, read_repository, write_repository\n'
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/glab"
  install_stub xdg-open ""
}
teardown() { auth_teardown_common; }

@test "gitlab store + status reports scopes from glab" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'glpat-0123456789abcdef0123\n' >"${tf}"
  scripts/auth/gitlab.sh store volk "${tf}"
  run scripts/auth/gitlab.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=gitlab"* ]]
  [[ "${output}" == *"scopes=api, read_repository, write_repository"* ]]
  [[ "${output}" != *"glpat-0123456789abcdef0123"* ]]
}

@test "gitlab exec sets GITLAB_TOKEN" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'glpat-0123456789abcdef0123\n' >"${tf}"
  scripts/auth/gitlab.sh store volk "${tf}"
  run scripts/auth/gitlab.sh exec volk -- env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITLAB_TOKEN=glpat-0123456789abcdef0123"* ]]
}

@test "gitlab destroy removes file" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'glpat-token\n' >"${tf}"
  scripts/auth/gitlab.sh store volk "${tf}"
  scripts/auth/gitlab.sh destroy volk
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.gitlab.pat" ]
}

@test "gitlab rotate via DEVAGENT_ROTATE_TOKEN_FILE swaps in place" {
  local tf1="${BATS_TEST_TMPDIR}/t1" tf2="${BATS_TEST_TMPDIR}/t2"
  printf 'glpat-AAAA\n' >"${tf1}"
  printf 'glpat-BBBB\n' >"${tf2}"
  scripts/auth/gitlab.sh store volk "${tf1}"
  env DEVAGENT_ROTATE_TOKEN_FILE="${tf2}" scripts/auth/gitlab.sh rotate volk
  [ "$(cat "${DEVAGENT_SECRETS_DIR}/volk.gitlab.pat")" = "glpat-BBBB" ]
}

@test "gitlab status with no token says present=false" {
  run scripts/auth/gitlab.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"present=false"* ]]
}

# --- #91: attributable validation, fail closed -----------------------------

@test "gitlab store fails closed on an invalid token — no secret written (#91)" {
  cat >"${STUB_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") printf 'HTTP/2 401 Unauthorized\r\n'; exit 1 ;;
esac
exit 1
EOF
  chmod +x "${STUB_BIN}/glab"
  local tf="${BATS_TEST_TMPDIR}/tok"; printf 'glpat-0123456789abcdef0123\n' >"${tf}"
  run scripts/auth/gitlab.sh store volk "${tf}"
  [ "${status}" -ne 0 ]
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.gitlab.pat" ]
}

@test "gitlab scopes line is not truncated at an 'n' (#95)" {
  cat >"${STUB_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") exit 0 ;;
  "api personal_access_tokens/self") printf 'admin_mode, api, write_repository\n'; exit 0 ;;
  "auth status") printf 'Token scopes: admin_mode, api, write_repository\n'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/glab"
  local tf="${BATS_TEST_TMPDIR}/tok"; printf 'glpat-0123456789abcdef0123\n' >"${tf}"
  scripts/auth/gitlab.sh store volk "${tf}"
  run scripts/auth/gitlab.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"admin_mode"* ]]        # not truncated at the 'n' in admin_mode
  [[ "${output}" == *"write_repository"* ]]  # the tail survives
}
