load 'helpers/auth_setup'

setup() {
  auth_setup_common
  export DEVAGENT_JIRA_BASE="https://example.atlassian.net"
  export DEVAGENT_JIRA_EMAIL="dev@example.com"
  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
if printf '%s' "$*" | grep -q '/rest/api/3/myself'; then
  printf '{"accountId":"abc","emailAddress":"dev@example.com"}\n'
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/curl"
  install_stub xdg-open ""
}
teardown() { auth_teardown_common; }

@test "jira store + status validates via curl, never prints token" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ATATT3xFfGF0jiraToken12345\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=jira"* ]]
  [[ "${output}" == *"accountId=abc"* ]]
  [[ "${output}" != *"ATATT3xFfGF0jiraToken12345"* ]]
}

@test "jira validate sends the credential via --config stdin, not argv (#92)" {
  local stdin_log="${BATS_TEST_TMPDIR}/curl.stdin"
  cat >"${STUB_BIN}/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${STUB_LOG}"
cat >>"${stdin_log}"
printf '{"accountId":"abc"}\n'
EOF
  chmod +x "${STUB_BIN}/curl"
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ATATT3xSECRETtoken9\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh status volk
  [ "${status}" -eq 0 ]
  ! grep -q 'ATATT3xSECRETtoken9' "${STUB_LOG}"   # token NOT in curl argv
  grep -q -- '--config' "${STUB_LOG}"             # used --config
  grep -q 'ATATT3xSECRETtoken9' "${stdin_log}"    # delivered via stdin
}

@test "jira exec sets JIRA_TOKEN and JIRA_USER (#94)" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ATATT3xFfGF0jiraToken12345\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh exec volk -- env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"JIRA_TOKEN=ATATT3xFfGF0jiraToken12345"* ]]
  [[ "${output}" == *"JIRA_USER=dev@example.com"* ]]   # #94: from DEVAGENT_JIRA_EMAIL, for Basic auth
}

@test "jira create validates the token and reports the result (#94)" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ATATT3xFfGF0jiraToken12345\n' >"${tf}"
  run env DEVAGENT_CREATE_TOKEN_FILE="${tf}" scripts/auth/jira.sh create volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"accountId=abc"* ]]               # #94: _ji_validate ran in create
}

@test "jira destroy removes file" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'jiratoken\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  scripts/auth/jira.sh destroy volk
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.jira.pat" ]
}

@test "jira rotate via DEVAGENT_ROTATE_TOKEN_FILE swaps in place" {
  local tf1="${BATS_TEST_TMPDIR}/t1" tf2="${BATS_TEST_TMPDIR}/t2"
  printf 'AAAA\n' >"${tf1}"
  printf 'BBBB\n' >"${tf2}"
  scripts/auth/jira.sh store volk "${tf1}"
  env DEVAGENT_ROTATE_TOKEN_FILE="${tf2}" scripts/auth/jira.sh rotate volk
  [ "$(cat "${DEVAGENT_SECRETS_DIR}/volk.jira.pat")" = "BBBB" ]
}

@test "jira status without DEVAGENT_JIRA_BASE warns and omits validation (#94)" {
  unset DEVAGENT_JIRA_BASE
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'jiratoken\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"validation_skipped=DEVAGENT_JIRA_BASE_unset"* ]]
}
