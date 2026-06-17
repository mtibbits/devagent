load 'helpers/auth_setup'

setup() {
  auth_setup_common
  install_stub gh ""
  install_stub xdg-open ""
}
teardown() { auth_teardown_common; }

@test "token file mode is exactly 600" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "secrets directory mode is exactly 700" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
}

@test "secrets directory is auto-corrected to 700 if loose" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  mkdir -p "${DEVAGENT_SECRETS_DIR}"
  chmod 755 "${DEVAGENT_SECRETS_DIR}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
}

@test "exec never puts the token on the command line" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" exec volk -- sleep 5 &
  local pid=$!
  sleep 1
  local snapshot
  snapshot="$(ps -wwo args= -p "${pid}" 2>/dev/null || true)"
  local full_tree
  full_tree="$(ps -ww -ef 2>/dev/null || true)"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  [[ "${snapshot}"   != *"ghp_0123456789abcdef"* ]]
  [[ "${full_tree}"  != *"ghp_0123456789abcdef"* ]]
}

@test "secret_read prints only the value, no trailing log noise" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  secret_write volk github "$(synthetic_token)"
  local got
  got="$(secret_read volk github)"
  [ "${got}" = "ghp_0123456789abcdef0123456789abcdef0123" ]
}

@test "destroy leaves no traces of the token on disk" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" destroy volk
  run grep -RIl 'ghp_0123456789abcdef' "${DEVAGENT_SECRETS_DIR}" 2>/dev/null
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "store accepts token files outside HOME (only mode on stored file is enforced)" {
  local tf="/tmp/devagent-tok-$$"
  synthetic_token >"${tf}"
  run "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  rm -f "${tf}"
  [ "${status}" -eq 0 ]
}

@test "a proven-invalid token is never written to disk (#91 fail-closed)" {
  # gh reports the candidate is unauthorized (401) and exits non-zero.
  cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 401 Unauthorized\r\n'
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
  local tf="${BATS_TEST_TMPDIR}/tok"; synthetic_token >"${tf}"
  run "${BATS_TEST_DIRNAME}/../scripts/auth/github.sh" store volk "${tf}"
  [ "${status}" -ne 0 ]
  [ ! -e "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]   # the security invariant
}
