load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "auth_common parses 'create <project>'" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  auth_parse_args create volk
  [ "${AUTH_VERB}" = "create" ]
  [ "${AUTH_PROJECT}" = "volk" ]
}

@test "auth_common parses 'exec <project> -- cmd args'" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  auth_parse_args exec volk -- env
  [ "${AUTH_VERB}" = "exec" ]
  [ "${AUTH_PROJECT}" = "volk" ]
  [ "${#AUTH_EXEC_CMD[@]}" -eq 1 ]
  [ "${AUTH_EXEC_CMD[0]}" = "env" ]
}

@test "auth_common parses 'exec' with multi-word cmd" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  auth_parse_args exec volk -- bash -c "echo hi"
  [ "${AUTH_VERB}" = "exec" ]
  [ "${#AUTH_EXEC_CMD[@]}" -eq 3 ]
}

@test "auth_common parses 'store <project> <token-file>'" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  auth_parse_args store volk /tmp/tok
  [ "${AUTH_VERB}" = "store" ]
  [ "${AUTH_PROJECT}" = "volk" ]
  [ "${AUTH_TOKEN_FILE}" = "/tmp/tok" ]
}

@test "auth_common rejects unknown verb" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  run auth_parse_args bogus volk
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown verb"* ]]
}

@test "auth_common rejects missing project" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  run auth_parse_args create
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"project required"* ]]
}

@test "auth_common rejects 'exec' without --" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  run auth_parse_args exec volk env
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires '--'"* ]]
}

@test "auth_run_exec sets env var and execs without leaking token in argv" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  source "${BATS_TEST_DIRNAME}/../scripts/lib/auth_common.sh"
  secret_write volk github "$(synthetic_token)"
  run auth_run_exec volk github GH_TOKEN env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GH_TOKEN=ghp_0123456789abcdef"* ]]
}
