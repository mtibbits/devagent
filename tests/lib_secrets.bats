load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "secret_write creates dir 0700 and file 0600" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  secret_write volk github "$(synthetic_token)"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "secret_read returns the stored value" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  local tok; tok="$(synthetic_token)"
  secret_write volk github "${tok}"
  run secret_read volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tok}" ]
}

@test "secret_read on missing key exits 2 with empty stdout" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_read volk github
  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
}

@test "secret_destroy shreds and unlinks" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  secret_write volk github "$(synthetic_token)"
  local f="${DEVAGENT_SECRETS_DIR}/volk.github.pat"
  [ -f "${f}" ]
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
  [ ! -e "${f}" ]
}

@test "secret_destroy on missing key exits 0 (idempotent)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
}

@test "secret_stat reports backend, mtime, size; never the value" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
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
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_path volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "secret_write rejects empty project name" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_write "" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects empty backend name" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_write volk "" "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects project names with slashes" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_write "vo/lk" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_backend defaults to 'file' and respects override" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  run secret_backend
  [ "${output}" = "file" ]
  DEVAGENT_SECRETS_BACKEND=keyring run secret_backend
  [ "${output}" = "keyring" ]
}

@test "keyring backend is not implemented in v1 and errors clearly" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  DEVAGENT_SECRETS_BACKEND=keyring run secret_write volk github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"keyring backend not implemented"* ]]
}

# --- #289: posix_modes_representable + secrets_audit skip ---------------------

@test "posix_modes_representable is true where chmod works (#289)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  local d="${BATS_TEST_TMPDIR}/sd"; mkdir -p "$d"
  # Precondition: this assertion only holds where chmod actually changes
  # modes. On a no-op-chmod filesystem (Windows/noacl NTFS) the probe
  # correctly returns false, so skip rather than falsely fail there.
  local t="$d/.pc"; : > "$t"; chmod 600 "$t"
  [ "$(stat -c '%a' "$t" 2>/dev/null)" = 600 ] || skip "chmod is a no-op on this filesystem"
  rm -f "$t"
  run posix_modes_representable "$d"
  [ "$status" -eq 0 ]
}

@test "posix_modes_representable is FALSE when chmod is a no-op (#289 probe false branch, AC#4)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  # Drive the probe's real false branch on a POSIX box: stub chmod to a
  # no-op (like noacl NTFS) and stat to always report 644, so the probe
  # creates+"chmod"s a file that reads back != 600 → unrepresentable.
  local stub="${BATS_TEST_TMPDIR}/stub"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 0\n'  > "$stub/chmod"
  printf '#!/usr/bin/env bash\necho 644\n' > "$stub/stat"
  chmod +x "$stub/chmod" "$stub/stat"     # real chmod — stub not on PATH yet
  local d="${BATS_TEST_TMPDIR}/sd2"; mkdir -p "$d"
  local oldpath="$PATH"; PATH="$stub:$PATH"
  run posix_modes_representable "$d"
  PATH="$oldpath"
  [ "$status" -eq 1 ]
}

@test "posix_modes_representable errs toward auditing on an unprobeable dir (#289 AC#3)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  # Non-existent dir → mktemp fails → return 0 (representable → audit runs).
  run posix_modes_representable "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$status" -eq 0 ]
}

@test "secrets_audit SKIPS and passes when modes are unrepresentable (#289)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  posix_modes_representable() { return 1; }   # force unrepresentable
  mkdir -p "${DEVAGENT_SECRETS_DIR}"; chmod 755 "${DEVAGENT_SECRETS_DIR}" 2>/dev/null || true
  run secrets_audit
  [ "$status" -eq 0 ]                          # skipped, not failed
  [[ "$output" == *"does not represent POSIX modes"* ]]
}

@test "secrets_audit still FAILs on real drift where modes ARE representable (#289 Unix-unchanged)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/secrets.sh"
  posix_modes_representable() { return 0; }   # force representable (POSIX path)
  mkdir -p "${DEVAGENT_SECRETS_DIR}"; chmod 755 "${DEVAGENT_SECRETS_DIR}" 2>/dev/null || true
  run secrets_audit
  [ "$status" -ne 0 ]                          # drift still detected
}
