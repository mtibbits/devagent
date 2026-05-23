load 'helpers/auth_setup'

setup() {
  auth_setup_common
  export DEVAGENT_JIRA_BASE_URL="https://example.atlassian.net"
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

@test "jira exec sets JIRA_TOKEN" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'ATATT3xFfGF0jiraToken12345\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh exec volk -- env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"JIRA_TOKEN=ATATT3xFfGF0jiraToken12345"* ]]
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

@test "jira status without DEVAGENT_JIRA_BASE_URL warns and omits validation" {
  unset DEVAGENT_JIRA_BASE_URL
  local tf="${BATS_TEST_TMPDIR}/tok"
  printf 'jiratoken\n' >"${tf}"
  scripts/auth/jira.sh store volk "${tf}"
  run scripts/auth/jira.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"validation_skipped=DEVAGENT_JIRA_BASE_URL_unset"* ]]
}
