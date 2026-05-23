# tests/helpers/auth_setup.bash
# Shared setup for all auth-related bats tests.
# Provides:
#   - isolated HOME under $BATS_TEST_TMPDIR
#   - DEVAGENT_SECRETS_DIR convenience var
#   - synthetic_token() — emits a deterministic 40-char hex token
#   - stub_browser, stub_clipboard, stub_gh, stub_glab, stub_curl
#     all install fake commands first on PATH
#   - assert_mode <file> <mode> — POSIX mode assertion via stat

auth_setup_common() {
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  export DEVAGENT_ROOT="${HOME}/.claude/devagent"
  export DEVAGENT_SECRETS_DIR="${DEVAGENT_ROOT}/secrets"
  export DEVAGENT_STATE_DIR="${DEVAGENT_ROOT}/state"
  export PATH_ORIG="${PATH}"
  export STUB_BIN="${BATS_TEST_TMPDIR}/stubs"
  mkdir -p "${STUB_BIN}"
  export PATH="${STUB_BIN}:${PATH}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log"
  : > "${STUB_LOG}"
}

auth_teardown_common() {
  export PATH="${PATH_ORIG}"
}

synthetic_token() {
  printf 'ghp_0123456789abcdef0123456789abcdef0123\n'
}

# Install a stub named $1 that records "$1 $*" to $STUB_LOG and prints $2 to stdout.
install_stub() {
  local name="$1"; shift
  local stdout_payload="${1:-}"
  local exit_code="${2:-0}"
  cat >"${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"${STUB_LOG}"
if [ -n "${stdout_payload}" ]; then
  printf '%s\n' "${stdout_payload}"
fi
exit ${exit_code}
EOF
  chmod +x "${STUB_BIN}/${name}"
}

# Install a stub that reads stdin and copies it to $STUB_BIN/<name>.stdin
install_stub_capturing_stdin() {
  local name="$1"; shift
  local exit_code="${1:-0}"
  cat >"${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"${STUB_LOG}"
cat >"${STUB_BIN}/${name}.stdin"
exit ${exit_code}
EOF
  chmod +x "${STUB_BIN}/${name}"
}

assert_mode() {
  local f="$1" expected="$2"
  local actual
  actual="$(stat -c '%a' "${f}")"
  [ "${actual}" = "${expected}" ] || {
    echo "expected mode ${expected} on ${f}, got ${actual}" >&2
    return 1
  }
}
