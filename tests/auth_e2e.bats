# Full lifecycle smoke test: store → status → exec → rotate → destroy
# for each PAT backend, exercising the public verb surface end-to-end.
load 'helpers/auth_setup'

setup() {
  auth_setup_common
  install_stub gh "Token scopes: 'repo', 'workflow'"
  install_stub glab "Token scopes: 'api'"
  install_stub xdg-open ""
  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"accountId":"abc"}\n'
exit 0
EOF
  chmod +x "${STUB_BIN}/curl"
  export DEVAGENT_JIRA_BASE="https://example.atlassian.net"
  export DEVAGENT_JIRA_EMAIL="dev@example.com"
}
teardown() { auth_teardown_common; }

_full_cycle() {
  local backend="$1" envvar="$2"
  local tf1="${BATS_TEST_TMPDIR}/${backend}.tok1"
  local tf2="${BATS_TEST_TMPDIR}/${backend}.tok2"
  printf 'tok-AAAA-%s-AAAA\n' "${backend}" >"${tf1}"
  printf 'tok-BBBB-%s-BBBB\n' "${backend}" >"${tf2}"

  scripts/auth/${backend}.sh store volk "${tf1}"
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.${backend}.pat" 600

  run scripts/auth/${backend}.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=${backend}"* ]]

  run scripts/auth/${backend}.sh exec volk -- env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${envvar}=tok-AAAA-${backend}-AAAA"* ]]

  env DEVAGENT_ROTATE_TOKEN_FILE="${tf2}" scripts/auth/${backend}.sh rotate volk
  [ "$(cat "${DEVAGENT_SECRETS_DIR}/volk.${backend}.pat")" = "tok-BBBB-${backend}-BBBB" ]

  scripts/auth/${backend}.sh destroy volk
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.${backend}.pat" ]
}

@test "github full cycle: store -> status -> exec -> rotate -> destroy" {
  _full_cycle github GH_TOKEN
}

@test "gitlab full cycle" {
  _full_cycle gitlab GITLAB_TOKEN
}

@test "jira full cycle" {
  _full_cycle jira JIRA_TOKEN
}
