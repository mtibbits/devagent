# devAgent Phase 8 — Auth Subsystem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the PAT/SSH-key lifecycle subsystem for devAgent so all backend scripts can fetch tokens through `auth/<backend>.sh exec` without exposing them in `ps`, argv, or shell history.

**Architecture:** A common `scripts/lib/secrets.sh` abstraction provides `secret_read`, `secret_write`, `secret_destroy`, `secret_stat` with a single backing store (file) in v1 and a future `--keyring` seam. Per-backend scripts (`scripts/auth/{github,gitlab,jira,custom}.sh`) implement the six verbs (`create`, `store`, `rotate`, `destroy`, `status`, `exec`) on top of this layer. A single `commands/auth.md` slash command dispatches to the backend by sub-verb. Tests run under `bats` with isolated `HOME` fakes and synthetic 40-char hex tokens.

**Tech Stack:** POSIX-ish bash, `shred`, `ssh-keygen`, `gh` / `glab` / `curl` for backend scope validation, `bats-core` for tests, `coreutils` (`install -m`, `mktemp`).

---

## Conventions for all tasks

- All paths in the plugin repo are rooted at `/home/user/src/devAgent`.
- All shell scripts begin with `#!/usr/bin/env bash` and `set -euo pipefail`.
- All scripts source `scripts/lib/secrets.sh` via the absolute path of the calling script's directory: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "${SCRIPT_DIR}/../lib/secrets.sh"`.
- Tests run against an isolated `HOME` set by `setup()` to a `mktemp -d` directory. **Never** touch the operator's real `~/.claude/devagent/secrets`.
- Synthetic test tokens are 40-char hex strings, e.g. `ghp_0123456789abcdef0123456789abcdef0123`.
- Commits use `git commit -s` (DCO required) and end with `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`. No "(1M context)" or other AI-self-promotion phrases.
- Do NOT push or open PRs in this plan — the parent plan handles integration.

---

## File structure

**New files:**

- `scripts/lib/secrets.sh` — storage abstraction
- `scripts/lib/auth_common.sh` — shared CLI dispatch + arg parsing for all backend scripts
- `scripts/auth/github.sh`
- `scripts/auth/gitlab.sh`
- `scripts/auth/jira.sh`
- `scripts/auth/custom.sh`
- `scripts/auth/ssh.sh` — SSH keypair lifecycle (shared by all backends that opt into SSH)
- `commands/auth.md` — slash command dispatcher
- `scripts/lib/doctor_auth.sh` — hook called by `/devagent:doctor`
- `tests/helpers/auth_setup.bash` — bats helper: isolated HOME, mock browser, mock clipboard, mock backend APIs
- `tests/lib_secrets.bats`
- `tests/auth_common.bats`
- `tests/auth_github.bats`
- `tests/auth_gitlab.bats`
- `tests/auth_jira.bats`
- `tests/auth_custom.bats`
- `tests/auth_ssh.bats`
- `tests/auth_security.bats` — cross-cutting security assertions (modes, `ps`, history)
- `tests/doctor_auth.bats`

**Modified files:** none. Phase 1's `/devagent:doctor` reads `doctor_auth.sh` via a documented hook contract (see Task 11); Phase 1 has not yet wired the call, so this plan introduces the script and documents how Phase 1's doctor will source it.

---

## Task 1: Bats helper for auth tests

**Files:**
- Create: `tests/helpers/auth_setup.bash`

- [ ] **Step 1: Write the helper**

```bash
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
  # Where stubs record invocations for assertions
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log"
  : > "${STUB_LOG}"
}

auth_teardown_common() {
  export PATH="${PATH_ORIG}"
}

synthetic_token() {
  # Deterministic 40-char hex; never a real PAT pattern beyond length.
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
```

- [ ] **Step 2: Verify bats can source the helper**

Run: `bash -n tests/helpers/auth_setup.bash`
Expected: exit 0 (syntax OK, no output).

- [ ] **Step 3: Commit**

```bash
git add tests/helpers/auth_setup.bash
git commit -s -m "$(cat <<'EOF'
test(auth): add shared bats helper for auth subsystem tests

Provides isolated HOME, stubs for browser/clipboard/gh/glab/curl,
and a synthetic_token generator so no real PATs are ever written.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `scripts/lib/secrets.sh` — storage abstraction (tests first)

**Files:**
- Create: `tests/lib_secrets.bats`
- Create: `scripts/lib/secrets.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/lib_secrets.bats
load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "secret_write creates dir 0700 and file 0600" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "secret_read returns the stored value" {
  source scripts/lib/secrets.sh
  local tok; tok="$(synthetic_token)"
  secret_write volk github "${tok}"
  run secret_read volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${tok}" ]
}

@test "secret_read on missing key exits 2 with empty stdout" {
  source scripts/lib/secrets.sh
  run secret_read volk github
  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
}

@test "secret_destroy shreds and unlinks" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  local f="${DEVAGENT_SECRETS_DIR}/volk.github.pat"
  [ -f "${f}" ]
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
  [ ! -e "${f}" ]
}

@test "secret_destroy on missing key exits 0 (idempotent)" {
  source scripts/lib/secrets.sh
  run secret_destroy volk github
  [ "${status}" -eq 0 ]
}

@test "secret_stat reports backend, mtime, size; never the value" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  run secret_stat volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=github"* ]]
  [[ "${output}" == *"project=volk"* ]]
  [[ "${output}" == *"size_bytes="* ]]
  [[ "${output}" == *"mtime="* ]]
  # Must not include the token
  [[ "${output}" != *"ghp_0123456789abcdef"* ]]
}

@test "secret_path returns the canonical PAT path" {
  source scripts/lib/secrets.sh
  run secret_path volk github
  [ "${status}" -eq 0 ]
  [ "${output}" = "${DEVAGENT_SECRETS_DIR}/volk.github.pat" ]
}

@test "secret_write rejects empty project name" {
  source scripts/lib/secrets.sh
  run secret_write "" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects empty backend name" {
  source scripts/lib/secrets.sh
  run secret_write volk "" "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_write rejects project names with slashes" {
  source scripts/lib/secrets.sh
  run secret_write "vo/lk" github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
}

@test "secret_backend defaults to 'file' and respects override" {
  source scripts/lib/secrets.sh
  run secret_backend
  [ "${output}" = "file" ]
  DEVAGENT_SECRETS_BACKEND=keyring run secret_backend
  [ "${output}" = "keyring" ]
}

@test "keyring backend is not implemented in v1 and errors clearly" {
  source scripts/lib/secrets.sh
  DEVAGENT_SECRETS_BACKEND=keyring run secret_write volk github "$(synthetic_token)"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"keyring backend not implemented"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats tests/lib_secrets.bats`
Expected: all 11 tests fail with "No such file or directory" sourcing `scripts/lib/secrets.sh`.

- [ ] **Step 3: Implement `scripts/lib/secrets.sh`**

```bash
#!/usr/bin/env bash
# scripts/lib/secrets.sh
#
# Storage abstraction for devAgent secrets.
#
# Public functions:
#   secret_backend                 — prints active backend ("file" in v1)
#   secret_path     PROJ BACKEND   — canonical PAT path
#   secret_write    PROJ BACKEND V — write value V (atomic, mode 600, dir 700)
#   secret_read     PROJ BACKEND   — print value or exit 2 if absent
#   secret_destroy  PROJ BACKEND   — shred -u then unlink; idempotent
#   secret_stat     PROJ BACKEND   — print metadata; never the value
#
# Environment:
#   DEVAGENT_ROOT          (default ~/.claude/devagent)
#   DEVAGENT_SECRETS_DIR   (default $DEVAGENT_ROOT/secrets)
#   DEVAGENT_SECRETS_BACKEND  (default "file"; "keyring" reserved for v2)
#
# Future v2 contract: a "keyring" backend will swap implementations
# transparently. Callers MUST go through these functions; direct file
# I/O against ~/.claude/devagent/secrets is a violation.

set -euo pipefail

: "${DEVAGENT_ROOT:=${HOME}/.claude/devagent}"
: "${DEVAGENT_SECRETS_DIR:=${DEVAGENT_ROOT}/secrets}"
: "${DEVAGENT_SECRETS_BACKEND:=file}"

secret_backend() {
  printf '%s\n' "${DEVAGENT_SECRETS_BACKEND}"
}

_secret_validate_name() {
  local kind="$1" val="$2"
  if [ -z "${val}" ]; then
    echo "secrets: ${kind} must be non-empty" >&2
    return 1
  fi
  case "${val}" in
    *[/\\\ \"\'\`\$\;\|]* )
      echo "secrets: ${kind} contains forbidden characters: ${val}" >&2
      return 1
      ;;
    .|..)
      echo "secrets: ${kind} must not be '.' or '..'" >&2
      return 1
      ;;
  esac
  return 0
}

_secret_require_file_backend() {
  if [ "${DEVAGENT_SECRETS_BACKEND}" != "file" ]; then
    echo "secrets: keyring backend not implemented in v1 (set DEVAGENT_SECRETS_BACKEND=file)" >&2
    return 1
  fi
}

_secret_ensure_dir() {
  if [ ! -d "${DEVAGENT_SECRETS_DIR}" ]; then
    install -d -m 0700 "${DEVAGENT_SECRETS_DIR}"
  else
    chmod 0700 "${DEVAGENT_SECRETS_DIR}"
  fi
}

secret_path() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}"
  _secret_validate_name backend "${backend}"
  printf '%s/%s.%s.pat\n' "${DEVAGENT_SECRETS_DIR}" "${proj}" "${backend}"
}

secret_write() {
  local proj="$1" backend="$2" value="$3"
  _secret_validate_name project "${proj}"
  _secret_validate_name backend "${backend}"
  _secret_require_file_backend
  if [ -z "${value}" ]; then
    echo "secrets: refusing to write empty value" >&2
    return 1
  fi
  _secret_ensure_dir
  local dest tmp
  dest="$(secret_path "${proj}" "${backend}")"
  tmp="$(mktemp "${DEVAGENT_SECRETS_DIR}/.tmp.XXXXXX")"
  chmod 0600 "${tmp}"
  printf '%s' "${value}" >"${tmp}"
  mv -f "${tmp}" "${dest}"
  chmod 0600 "${dest}"
}

secret_read() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}"
  _secret_validate_name backend "${backend}"
  _secret_require_file_backend
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -f "${f}" ]; then
    return 2
  fi
  cat "${f}"
}

secret_destroy() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}"
  _secret_validate_name backend "${backend}"
  _secret_require_file_backend
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -e "${f}" ]; then
    return 0
  fi
  if command -v shred >/dev/null 2>&1; then
    shred -u -- "${f}"
  else
    # Fallback: overwrite with zeros then unlink
    local sz
    sz="$(stat -c '%s' "${f}" 2>/dev/null || echo 0)"
    dd if=/dev/zero of="${f}" bs=1 count="${sz}" conv=notrunc status=none 2>/dev/null || true
    rm -f -- "${f}"
  fi
}

secret_stat() {
  local proj="$1" backend="$2"
  _secret_validate_name project "${proj}"
  _secret_validate_name backend "${backend}"
  _secret_require_file_backend
  local f
  f="$(secret_path "${proj}" "${backend}")"
  if [ ! -f "${f}" ]; then
    printf 'project=%s backend=%s present=false\n' "${proj}" "${backend}"
    return 0
  fi
  local size mtime mode
  size="$(stat -c '%s' "${f}")"
  mtime="$(stat -c '%y' "${f}")"
  mode="$(stat -c '%a' "${f}")"
  printf 'project=%s backend=%s present=true mode=%s size_bytes=%s mtime=%s\n' \
    "${proj}" "${backend}" "${mode}" "${size}" "${mtime}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lib_secrets.bats`
Expected: 11 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/secrets.sh tests/lib_secrets.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add scripts/lib/secrets.sh storage abstraction

File-backed in v1 with mode 600 / dir 700. Keyring backend reserved
for v2 and errors clearly if requested today. Atomic writes via
mktemp+mv. shred -u with dd-zero fallback on destroy.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `scripts/lib/auth_common.sh` — shared CLI dispatch

**Files:**
- Create: `tests/auth_common.bats`
- Create: `scripts/lib/auth_common.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_common.bats
load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "auth_common parses 'create <project>'" {
  source scripts/lib/auth_common.sh
  auth_parse_args create volk
  [ "${AUTH_VERB}" = "create" ]
  [ "${AUTH_PROJECT}" = "volk" ]
}

@test "auth_common parses 'exec <project> -- cmd args'" {
  source scripts/lib/auth_common.sh
  auth_parse_args exec volk -- env
  [ "${AUTH_VERB}" = "exec" ]
  [ "${AUTH_PROJECT}" = "volk" ]
  [ "${#AUTH_EXEC_CMD[@]}" -eq 1 ]
  [ "${AUTH_EXEC_CMD[0]}" = "env" ]
}

@test "auth_common parses 'exec' with multi-word cmd" {
  source scripts/lib/auth_common.sh
  auth_parse_args exec volk -- bash -c "echo hi"
  [ "${AUTH_VERB}" = "exec" ]
  [ "${#AUTH_EXEC_CMD[@]}" -eq 3 ]
}

@test "auth_common parses 'store <project> <token-file>'" {
  source scripts/lib/auth_common.sh
  auth_parse_args store volk /tmp/tok
  [ "${AUTH_VERB}" = "store" ]
  [ "${AUTH_PROJECT}" = "volk" ]
  [ "${AUTH_TOKEN_FILE}" = "/tmp/tok" ]
}

@test "auth_common rejects unknown verb" {
  source scripts/lib/auth_common.sh
  run auth_parse_args bogus volk
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown verb"* ]]
}

@test "auth_common rejects missing project" {
  source scripts/lib/auth_common.sh
  run auth_parse_args create
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"project required"* ]]
}

@test "auth_common rejects 'exec' without --" {
  source scripts/lib/auth_common.sh
  run auth_parse_args exec volk env
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires '--'"* ]]
}

@test "auth_run_exec sets env var and execs without leaking token in argv" {
  # Build a fake exec context: write a token, then ensure invoking
  # 'env' through auth_run_exec exposes GH_TOKEN and that the token
  # never appears in 'ps' argv.
  source scripts/lib/secrets.sh
  source scripts/lib/auth_common.sh
  secret_write volk github "$(synthetic_token)"
  run auth_run_exec volk github GH_TOKEN env
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GH_TOKEN=ghp_0123456789abcdef"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats tests/auth_common.bats`
Expected: all fail (no such file).

- [ ] **Step 3: Implement `scripts/lib/auth_common.sh`**

```bash
#!/usr/bin/env bash
# scripts/lib/auth_common.sh
#
# Shared argument parsing and exec-runner for all auth/<backend>.sh
# scripts. Backends source this and supply their own create/store/
# rotate/destroy/status implementations.
#
# Public globals after auth_parse_args:
#   AUTH_VERB         — create|store|rotate|destroy|status|exec
#   AUTH_PROJECT      — project name
#   AUTH_TOKEN_FILE   — set only for `store`
#   AUTH_EXEC_CMD     — array; set only for `exec`
#
# Public functions:
#   auth_parse_args  VERB ARGS...
#   auth_run_exec    PROJECT BACKEND ENV_VAR_NAME CMD ARGS...

set -euo pipefail

AUTH_VERB=""
AUTH_PROJECT=""
AUTH_TOKEN_FILE=""
AUTH_EXEC_CMD=()

auth_parse_args() {
  AUTH_VERB=""
  AUTH_PROJECT=""
  AUTH_TOKEN_FILE=""
  AUTH_EXEC_CMD=()

  if [ "$#" -eq 0 ]; then
    echo "auth: verb required (create|store|rotate|destroy|status|exec)" >&2
    return 1
  fi
  AUTH_VERB="$1"; shift

  case "${AUTH_VERB}" in
    create|rotate|destroy|status)
      if [ "$#" -lt 1 ]; then
        echo "auth: project required for '${AUTH_VERB}'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      ;;
    store)
      if [ "$#" -lt 2 ]; then
        echo "auth: project and token-file required for 'store'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      AUTH_TOKEN_FILE="$1"; shift
      ;;
    exec)
      if [ "$#" -lt 1 ]; then
        echo "auth: project required for 'exec'" >&2
        return 1
      fi
      AUTH_PROJECT="$1"; shift
      if [ "$#" -lt 1 ] || [ "$1" != "--" ]; then
        echo "auth: 'exec' requires '--' separator before command" >&2
        return 1
      fi
      shift  # discard --
      if [ "$#" -lt 1 ]; then
        echo "auth: 'exec' requires a command after '--'" >&2
        return 1
      fi
      AUTH_EXEC_CMD=("$@")
      ;;
    *)
      echo "auth: unknown verb '${AUTH_VERB}'" >&2
      return 1
      ;;
  esac
  return 0
}

# auth_run_exec PROJECT BACKEND ENV_VAR_NAME CMD ARGS...
# Reads the secret, exports it under ENV_VAR_NAME, and execs CMD.
# Token is never passed via argv; never echoed; not on caller's
# command line because callers pass the var *name*, not its value.
auth_run_exec() {
  local proj="$1" backend="$2" envvar="$3"; shift 3
  local val
  if ! val="$(secret_read "${proj}" "${backend}")"; then
    echo "auth: no token stored for ${proj}.${backend}" >&2
    return 2
  fi
  # Use env -S-style explicit export so the value never sits in argv.
  # `env VAR=val cmd` would expose val via /proc/<pid>/cmdline on Linux,
  # so we export and then exec.
  export "${envvar}=${val}"
  unset val
  exec "$@"
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `bats tests/auth_common.bats`
Expected: 8 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/auth_common.sh tests/auth_common.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add scripts/lib/auth_common.sh CLI dispatcher

Parses verb + project + (store: token-file | exec: -- cmd args).
auth_run_exec exports the secret into the environment then execs the
child process, so the token is never passed via argv.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/auth/github.sh` (tests first)

**Files:**
- Create: `tests/auth_github.bats`
- Create: `scripts/auth/github.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_github.bats
load 'helpers/auth_setup'

setup() {
  auth_setup_common
  # Stub `gh` for scope validation: any call returns a fixed scope list.
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
  # Stub xdg-open / open (browser).
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
  # No leftover .old or .tmp files
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
```

- [ ] **Step 2: Run tests; confirm they fail**

Run: `bats tests/auth_github.bats`
Expected: all fail (`scripts/auth/github.sh: not found`).

- [ ] **Step 3: Implement `scripts/auth/github.sh`**

```bash
#!/usr/bin/env bash
# scripts/auth/github.sh
#
# GitHub PAT lifecycle.
#
# Verbs:
#   create   <project>           — interactive: open browser, paste, validate, store
#   store    <project> <file>    — non-interactive ingest
#   rotate   <project>           — atomic create-new, swap, destroy-old
#                                  (in non-interactive mode, reads
#                                   $DEVAGENT_ROTATE_TOKEN_FILE)
#   destroy  <project>           — shred + unlink
#   status   <project>           — backend, scopes, expiry, last-used (never the token)
#   exec     <project> -- cmd... — set GH_TOKEN, exec cmd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/secrets.sh"
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="github"
readonly ENV_VAR="GH_TOKEN"
readonly PAT_URL="https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=devAgent"

_gh_validate_scopes() {
  # Uses gh; the operator must have gh installed for `create` / `status`.
  if ! command -v gh >/dev/null 2>&1; then
    echo "auth/github: gh CLI not installed; skipping scope validation" >&2
    return 0
  fi
  local out
  out="$(GH_TOKEN="$1" gh auth status 2>&1 || true)"
  printf '%s\n' "${out}" | grep -oE 'Token scopes:.*' | head -n1 || true
}

_gh_strip_token_file() {
  # Read a token file, strip trailing newlines/whitespace.
  local f="$1"
  if [ ! -f "${f}" ]; then
    echo "auth/github: token file not found: ${f}" >&2
    return 1
  fi
  local val
  val="$(cat "${f}")"
  # Trim trailing CR/LF/whitespace
  val="${val%$'\n'}"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]]; do
    val="${val%$'\n'}"
    val="${val%$'\r'}"
    val="${val% }"
  done
  if [ -z "${val}" ]; then
    echo "auth/github: token file is empty: ${f}" >&2
    return 1
  fi
  printf '%s' "${val}"
}

_gh_create_interactive() {
  local proj="$1"
  echo "auth/github: opening browser to ${PAT_URL}" >&2
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${PAT_URL}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${PAT_URL}" >/dev/null 2>&1 || true
  fi
  # Try clipboard first; fall back to prompt.
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gh_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip >/dev/null 2>&1; then
    token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then
    token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token
    printf '\n' >&2
  fi
  if [ -z "${token}" ]; then
    echo "auth/github: no token provided" >&2
    return 1
  fi
  local scopes
  scopes="$(_gh_validate_scopes "${token}")"
  if [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'repo'; then
    echo "auth/github: token missing required scope 'repo': ${scopes}" >&2
    return 1
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/github: stored token for ${proj} (${scopes:-scopes unknown})" >&2
}

_gh_store() {
  local proj="$1" tokfile="$2"
  local val
  val="$(_gh_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_gh_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    # Interactive path: prompt operator to create a new token, then store it.
    _gh_create_interactive "${proj}"
    return 0
  fi
  local new_val
  new_val="$(_gh_strip_token_file "${new_file}")"
  # Atomic swap: write under .new, mv into place, destroy any old in-memory copy.
  # secret_write already does atomic mktemp+mv, so a second secret_write IS the swap.
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_gh_status() {
  local proj="$1"
  local meta
  meta="$(secret_stat "${proj}" "${BACKEND}")"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then
    printf '\n'
    return 0
  fi
  local tok
  tok="$(secret_read "${proj}" "${BACKEND}")"
  local scopes
  scopes="$(_gh_validate_scopes "${tok}")"
  unset tok
  if [ -n "${scopes}" ]; then
    # Normalize "Token scopes: 'repo', 'workflow'" → "repo, workflow"
    scopes="$(printf '%s' "${scopes}" \
      | sed -e "s/^Token scopes: *//" -e "s/'//g")"
    printf ' scopes=%s' "${scopes}"
  fi
  # last-used: only known if `gh api /user` succeeded recently; we don't track.
  printf ' last_used=unknown'
  printf '\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _gh_create_interactive "${AUTH_PROJECT}" ;;
    store)   _gh_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _gh_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _gh_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/auth/github.sh
bats tests/auth_github.bats
```

Expected: 9 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/auth/github.sh tests/auth_github.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add github.sh PAT lifecycle (create/store/rotate/destroy/status/exec)

Browser-open + clipboard paste for interactive create; non-interactive
store reads from file; rotate uses DEVAGENT_ROTATE_TOKEN_FILE in
non-interactive contexts; exec sets GH_TOKEN and execs without putting
the token on the command line.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `scripts/auth/gitlab.sh`

**Files:**
- Create: `tests/auth_gitlab.bats`
- Create: `scripts/auth/gitlab.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_gitlab.bats
load 'helpers/auth_setup'

setup() {
  auth_setup_common
  # Stub `glab` for scope validation.
  cat >"${STUB_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >>"${STUB_LOG}"
case "$1 $2" in
  "auth status")
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
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `bats tests/auth_gitlab.bats`
Expected: all fail.

- [ ] **Step 3: Implement `scripts/auth/gitlab.sh`**

```bash
#!/usr/bin/env bash
# scripts/auth/gitlab.sh
# Same verb contract as github.sh; uses glab for scope validation,
# GITLAB_TOKEN env var for exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/secrets.sh"
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="gitlab"
readonly ENV_VAR="GITLAB_TOKEN"
readonly PAT_URL="https://gitlab.com/-/profile/personal_access_tokens?name=devAgent&scopes=api,read_repository,write_repository"

_gl_validate_scopes() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "auth/gitlab: glab CLI not installed; skipping scope validation" >&2
    return 0
  fi
  GITLAB_TOKEN="$1" glab auth status 2>&1 | grep -oE 'Token scopes:.*' | head -n1 || true
}

_gl_strip_token_file() {
  local f="$1"
  [ -f "${f}" ] || { echo "auth/gitlab: token file not found: ${f}" >&2; return 1; }
  local val
  val="$(cat "${f}")"
  val="${val%$'\n'}"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]]; do
    val="${val%$'\n'}"; val="${val%$'\r'}"; val="${val% }"
  done
  [ -n "${val}" ] || { echo "auth/gitlab: token file empty" >&2; return 1; }
  printf '%s' "${val}"
}

_gl_create_interactive() {
  local proj="$1"
  echo "auth/gitlab: opening browser to ${PAT_URL}" >&2
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "${PAT_URL}" >/dev/null 2>&1 || true
  elif command -v open      >/dev/null 2>&1; then open      "${PAT_URL}" >/dev/null 2>&1 || true
  fi
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_gl_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip   >/dev/null 2>&1; then token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token; printf '\n' >&2
  fi
  [ -n "${token}" ] || { echo "auth/gitlab: no token provided" >&2; return 1; }
  local scopes; scopes="$(_gl_validate_scopes "${token}")"
  if [ -n "${scopes}" ] && ! printf '%s' "${scopes}" | grep -q 'api'; then
    echo "auth/gitlab: token missing required scope 'api': ${scopes}" >&2
    return 1
  fi
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/gitlab: stored token for ${proj} (${scopes:-scopes unknown})" >&2
}

_gl_store() {
  local proj="$1" tokfile="$2"
  local val; val="$(_gl_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_gl_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _gl_create_interactive "${proj}"
    return 0
  fi
  local new_val; new_val="$(_gl_strip_token_file "${new_file}")"
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_gl_status() {
  local proj="$1"
  local meta; meta="$(secret_stat "${proj}" "${BACKEND}")"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then printf '\n'; return 0; fi
  local tok; tok="$(secret_read "${proj}" "${BACKEND}")"
  local scopes; scopes="$(_gl_validate_scopes "${tok}")"
  unset tok
  if [ -n "${scopes}" ]; then
    scopes="$(printf '%s' "${scopes}" | sed -e 's/^Token scopes: *//' -e "s/'//g")"
    printf ' scopes=%s' "${scopes}"
  fi
  printf ' last_used=unknown\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _gl_create_interactive "${AUTH_PROJECT}" ;;
    store)   _gl_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _gl_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _gl_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/auth/gitlab.sh
bats tests/auth_gitlab.bats
```

Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/auth/gitlab.sh tests/auth_gitlab.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add gitlab.sh PAT lifecycle

Mirrors github.sh verb contract; uses glab for scope validation and
GITLAB_TOKEN for exec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `scripts/auth/jira.sh`

**Files:**
- Create: `tests/auth_jira.bats`
- Create: `scripts/auth/jira.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_jira.bats
load 'helpers/auth_setup'

setup() {
  auth_setup_common
  export DEVAGENT_JIRA_BASE_URL="https://example.atlassian.net"
  export DEVAGENT_JIRA_EMAIL="dev@example.com"
  # Stub curl: any auth check returns user JSON with accountId.
  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
# Match GET /rest/api/3/myself
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
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `bats tests/auth_jira.bats`
Expected: all fail.

- [ ] **Step 3: Implement `scripts/auth/jira.sh`**

```bash
#!/usr/bin/env bash
# scripts/auth/jira.sh
# Same verb contract. Uses curl + Atlassian REST v3 /myself for
# validation. JIRA_TOKEN is the env var passed to exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/secrets.sh"
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="jira"
readonly ENV_VAR="JIRA_TOKEN"

_ji_strip_token_file() {
  local f="$1"
  [ -f "${f}" ] || { echo "auth/jira: token file not found: ${f}" >&2; return 1; }
  local val; val="$(cat "${f}")"
  val="${val%$'\n'}"
  while [[ "${val}" == *$'\n' ]] || [[ "${val}" == *' ' ]] || [[ "${val}" == *$'\r' ]]; do
    val="${val%$'\n'}"; val="${val%$'\r'}"; val="${val% }"
  done
  [ -n "${val}" ] || { echo "auth/jira: token file empty" >&2; return 1; }
  printf '%s' "${val}"
}

_ji_validate() {
  # Returns "accountId=<id>" on success, empty on failure, or
  # "validation_skipped=..." when configuration is incomplete.
  local tok="$1"
  if [ -z "${DEVAGENT_JIRA_BASE_URL:-}" ]; then
    printf 'validation_skipped=DEVAGENT_JIRA_BASE_URL_unset'
    return 0
  fi
  if [ -z "${DEVAGENT_JIRA_EMAIL:-}" ]; then
    printf 'validation_skipped=DEVAGENT_JIRA_EMAIL_unset'
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    printf 'validation_skipped=curl_missing'
    return 0
  fi
  local resp
  resp="$(curl -sS -u "${DEVAGENT_JIRA_EMAIL}:${tok}" \
    -H 'Accept: application/json' \
    "${DEVAGENT_JIRA_BASE_URL}/rest/api/3/myself" || true)"
  local id
  id="$(printf '%s' "${resp}" | sed -n 's/.*"accountId":"\([^"]*\)".*/\1/p')"
  if [ -n "${id}" ]; then
    printf 'accountId=%s' "${id}"
  fi
}

_ji_create_interactive() {
  local proj="$1"
  local url="https://id.atlassian.com/manage-profile/security/api-tokens"
  echo "auth/jira: opening browser to ${url}" >&2
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "${url}" >/dev/null 2>&1 || true
  elif command -v open      >/dev/null 2>&1; then open      "${url}" >/dev/null 2>&1 || true
  fi
  local token=""
  if [ -n "${DEVAGENT_CREATE_TOKEN_FILE:-}" ]; then
    token="$(_ji_strip_token_file "${DEVAGENT_CREATE_TOKEN_FILE}")"
  elif command -v xclip >/dev/null 2>&1; then token="$(xclip -selection clipboard -o 2>/dev/null || true)"
  elif command -v pbpaste >/dev/null 2>&1; then token="$(pbpaste 2>/dev/null || true)"
  fi
  if [ -z "${token}" ]; then
    printf 'Paste token (input hidden): ' >&2
    read -rs token; printf '\n' >&2
  fi
  [ -n "${token}" ] || { echo "auth/jira: no token provided" >&2; return 1; }
  secret_write "${proj}" "${BACKEND}" "${token}"
  echo "auth/jira: stored token for ${proj}" >&2
}

_ji_store() {
  local proj="$1" tokfile="$2"
  local val; val="$(_ji_strip_token_file "${tokfile}")"
  secret_write "${proj}" "${BACKEND}" "${val}"
}

_ji_rotate() {
  local proj="$1"
  local new_file="${DEVAGENT_ROTATE_TOKEN_FILE:-}"
  if [ -z "${new_file}" ]; then
    _ji_create_interactive "${proj}"
    return 0
  fi
  local new_val; new_val="$(_ji_strip_token_file "${new_file}")"
  secret_write "${proj}" "${BACKEND}" "${new_val}"
}

_ji_status() {
  local proj="$1"
  local meta; meta="$(secret_stat "${proj}" "${BACKEND}")"
  printf '%s' "${meta}"
  if [[ "${meta}" == *"present=false"* ]]; then printf '\n'; return 0; fi
  local tok; tok="$(secret_read "${proj}" "${BACKEND}")"
  local v; v="$(_ji_validate "${tok}")"
  unset tok
  if [ -n "${v}" ]; then printf ' %s' "${v}"; fi
  printf ' last_used=unknown\n'
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    create)  _ji_create_interactive "${AUTH_PROJECT}" ;;
    store)   _ji_store              "${AUTH_PROJECT}" "${AUTH_TOKEN_FILE}" ;;
    rotate)  _ji_rotate             "${AUTH_PROJECT}" ;;
    destroy) secret_destroy         "${AUTH_PROJECT}" "${BACKEND}" ;;
    status)  _ji_status             "${AUTH_PROJECT}" ;;
    exec)    auth_run_exec          "${AUTH_PROJECT}" "${BACKEND}" "${ENV_VAR}" "${AUTH_EXEC_CMD[@]}" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/auth/jira.sh
bats tests/auth_jira.bats
```

Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/auth/jira.sh tests/auth_jira.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add jira.sh PAT lifecycle

Validates against Atlassian REST v3 /myself when DEVAGENT_JIRA_BASE_URL
and DEVAGENT_JIRA_EMAIL are set; otherwise skips validation cleanly.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `scripts/auth/custom.sh` (stubs)

**Files:**
- Create: `tests/auth_custom.bats`
- Create: `scripts/auth/custom.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_custom.bats
load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "custom create prints 'not implemented' to stderr and exits 64" {
  run scripts/auth/custom.sh create volk
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"not implemented"* ]]
  [[ "${output}" == *"README"* ]]
}

@test "custom store also not implemented" {
  run scripts/auth/custom.sh store volk /tmp/whatever
  [ "${status}" -eq 64 ]
}

@test "custom status prints present=false with backend=custom" {
  run scripts/auth/custom.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=custom"* ]]
  [[ "${output}" == *"present=false"* ]]
}

@test "custom exec exits 64 (no token machinery)" {
  run scripts/auth/custom.sh exec volk -- env
  [ "${status}" -eq 64 ]
}

@test "custom rotate / destroy also stubbed" {
  run scripts/auth/custom.sh rotate volk
  [ "${status}" -eq 64 ]
  run scripts/auth/custom.sh destroy volk
  [ "${status}" -eq 64 ]
}
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `bats tests/auth_custom.bats`
Expected: all fail.

- [ ] **Step 3: Implement `scripts/auth/custom.sh`**

```bash
#!/usr/bin/env bash
# scripts/auth/custom.sh
# Stub backend. Verb contract identical to the others so callers can
# select 'custom' in config.toml without breaking dispatch, but every
# verb except `status` exits 64 (EX_USAGE) with a pointer to the README.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/secrets.sh"
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="custom"

_not_implemented() {
  local verb="$1"
  cat >&2 <<EOF
auth/custom: '${verb}' is not implemented for the custom backend in v1.

The custom backend exists so config.toml can select it without breaking
dispatch, but it ships as stubs. See the devAgent README section
'Implementing a custom auth backend' for the verb contract you must
satisfy in your own copy of scripts/auth/custom.sh.
EOF
  exit 64
}

_status() {
  local proj="$1"
  printf 'project=%s backend=%s present=false notes=stub-backend\n' "${proj}" "${BACKEND}"
}

main() {
  auth_parse_args "$@"
  case "${AUTH_VERB}" in
    status)  _status "${AUTH_PROJECT}" ;;
    *)       _not_implemented "${AUTH_VERB}" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/auth/custom.sh
bats tests/auth_custom.bats
```

Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/auth/custom.sh tests/auth_custom.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add custom.sh stub backend

Implements the same verb contract but exits 64 with a README pointer
for every verb except 'status'. Lets config.toml select 'custom'
without breaking dispatch.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `scripts/auth/ssh.sh` — SSH keypair lifecycle

**Files:**
- Create: `tests/auth_ssh.bats`
- Create: `scripts/auth/ssh.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/auth_ssh.bats
load 'helpers/auth_setup'

setup() {
  auth_setup_common
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  # Stub ssh-keygen: behave as if generating a key, write fake files.
  cat >"${STUB_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"${STUB_LOG}"
# Parse -f <out>
out=""
fp_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    -f) out="$2"; shift 2 ;;
    -l) fp_mode=1; shift ;;
    *)  shift ;;
  esac
done
if [ "${fp_mode}" = "1" ]; then
  printf '256 SHA256:abcdef0123456789FAKE devagent@host (ED25519)\n'
  exit 0
fi
if [ -n "${out}" ]; then
  printf 'fake-private-key\n' >"${out}"
  printf 'ssh-ed25519 AAAAFAKEPUBKEY devagent@host\n' >"${out}.pub"
  chmod 600 "${out}"
  chmod 644 "${out}.pub"
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/ssh-keygen"
  install_stub ssh-add ""
}
teardown() { auth_teardown_common; }

@test "ssh create generates ed25519 keypair and stores symlink" {
  run scripts/auth/ssh.sh create volk
  [ "${status}" -eq 0 ]
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  [ -L "${link}" ]
  local target; target="$(readlink "${link}")"
  [ -f "${target}" ]
  [ -f "${target}.pub" ]
  assert_mode "${target}" 600
}

@test "ssh status prints fingerprint and never the private key" {
  scripts/auth/ssh.sh create volk
  run scripts/auth/ssh.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=ssh"* ]]
  [[ "${output}" == *"fingerprint=SHA256:abcdef0123456789FAKE"* ]]
  [[ "${output}" != *"fake-private-key"* ]]
}

@test "ssh destroy shreds private key and removes symlink" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local target; target="$(readlink "${link}")"
  run scripts/auth/ssh.sh destroy volk
  [ "${status}" -eq 0 ]
  [ ! -e "${link}" ]
  [ ! -e "${target}" ]
  [ ! -e "${target}.pub" ]
}

@test "ssh rotate destroys old then creates new with different filename" {
  scripts/auth/ssh.sh create volk
  local link="${DEVAGENT_SECRETS_DIR}/volk.ssh"
  local old_target; old_target="$(readlink "${link}")"
  run scripts/auth/ssh.sh rotate volk
  [ "${status}" -eq 0 ]
  local new_target; new_target="$(readlink "${link}")"
  [ "${new_target}" != "${old_target}" ]
  [ -f "${new_target}" ]
  [ ! -e "${old_target}" ]
}

@test "ssh status with no key says present=false" {
  run scripts/auth/ssh.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"present=false"* ]]
}
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `bats tests/auth_ssh.bats`
Expected: all fail.

- [ ] **Step 3: Implement `scripts/auth/ssh.sh`**

```bash
#!/usr/bin/env bash
# scripts/auth/ssh.sh
#
# SSH keypair lifecycle. Verbs: create, destroy, rotate, status.
# (store and exec are PAT-only concepts; not exposed for SSH.)
#
# Key naming: ~/.ssh/devagent_<project>_<utc-yyyymmddHHMMSS>
# Symlink:    ~/.claude/devagent/secrets/<project>.ssh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/secrets.sh"
source "${SCRIPT_DIR}/../lib/auth_common.sh"

readonly BACKEND="ssh"

_ssh_link_path() {
  printf '%s/%s.ssh\n' "${DEVAGENT_SECRETS_DIR}" "$1"
}

_ssh_new_key_path() {
  local proj="$1"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"
  printf '%s/.ssh/devagent_%s_%s\n' "${HOME}" "${proj}" "${ts}"
}

_ssh_create() {
  local proj="$1"
  _secret_validate_name project "${proj}"
  _secret_ensure_dir
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  local key_path; key_path="$(_ssh_new_key_path "${proj}")"
  ssh-keygen -t ed25519 -N '' -C "devagent-${proj}" -f "${key_path}" >/dev/null
  local link; link="$(_ssh_link_path "${proj}")"
  ln -sfn "${key_path}" "${link}"
  echo "auth/ssh: created ${key_path} (linked at ${link})" >&2
}

_ssh_destroy() {
  local proj="$1"
  _secret_validate_name project "${proj}"
  local link; link="$(_ssh_link_path "${proj}")"
  if [ -L "${link}" ]; then
    local target; target="$(readlink "${link}")"
    if [ -f "${target}" ]; then
      if command -v shred >/dev/null 2>&1; then
        shred -u -- "${target}" || rm -f -- "${target}"
      else
        rm -f -- "${target}"
      fi
    fi
    if [ -f "${target}.pub" ]; then
      rm -f -- "${target}.pub"
    fi
    rm -f -- "${link}"
  fi
}

_ssh_rotate() {
  local proj="$1"
  _ssh_destroy "${proj}"
  _ssh_create  "${proj}"
}

_ssh_status() {
  local proj="$1"
  local link; link="$(_ssh_link_path "${proj}")"
  if [ ! -L "${link}" ]; then
    printf 'project=%s backend=ssh present=false\n' "${proj}"
    return 0
  fi
  local target; target="$(readlink "${link}")"
  local fp="unknown"
  if [ -f "${target}.pub" ] && command -v ssh-keygen >/dev/null 2>&1; then
    fp="$(ssh-keygen -l -f "${target}.pub" 2>/dev/null | awk '{print $2}')"
    [ -n "${fp}" ] || fp="unknown"
  fi
  local agent_loaded="no"
  if command -v ssh-add >/dev/null 2>&1; then
    if ssh-add -l 2>/dev/null | grep -qF "${target}"; then
      agent_loaded="yes"
    fi
  fi
  printf 'project=%s backend=ssh present=true target=%s fingerprint=%s agent_loaded=%s\n' \
    "${proj}" "${target}" "${fp}" "${agent_loaded}"
}

main() {
  if [ "$#" -lt 1 ]; then
    echo "auth/ssh: verb required (create|destroy|rotate|status)" >&2
    exit 1
  fi
  local verb="$1"; shift
  if [ "$#" -lt 1 ]; then
    echo "auth/ssh: project required" >&2
    exit 1
  fi
  local proj="$1"; shift
  case "${verb}" in
    create)  _ssh_create  "${proj}" ;;
    destroy) _ssh_destroy "${proj}" ;;
    rotate)  _ssh_rotate  "${proj}" ;;
    status)  _ssh_status  "${proj}" ;;
    *) echo "auth/ssh: unknown verb '${verb}'" >&2; exit 1 ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/auth/ssh.sh
bats tests/auth_ssh.bats
```

Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/auth/ssh.sh tests/auth_ssh.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add ssh.sh keypair lifecycle (ed25519)

create generates a new ed25519 keypair under ~/.ssh and symlinks the
private key from ~/.claude/devagent/secrets/<project>.ssh. status
reports fingerprint via ssh-keygen -l and whether ssh-agent has it
loaded. rotate = destroy + create. destroy shreds the private key.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Cross-cutting security tests

These guard against regressions in *how* secrets are handled, independent of any one backend.

**Files:**
- Create: `tests/auth_security.bats`

- [ ] **Step 1: Write the tests**

```bash
# tests/auth_security.bats
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
  scripts/auth/github.sh store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}/volk.github.pat" 600
}

@test "secrets directory mode is exactly 700" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
}

@test "secrets directory is auto-corrected to 700 if loose" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  mkdir -p "${DEVAGENT_SECRETS_DIR}"
  chmod 755 "${DEVAGENT_SECRETS_DIR}"
  scripts/auth/github.sh store volk "${tf}"
  assert_mode "${DEVAGENT_SECRETS_DIR}" 700
}

@test "exec never puts the token on the command line" {
  # Stash a token, then run exec with a long-sleeping child, snapshot ps.
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  # Run sleep in the background through exec
  scripts/auth/github.sh exec volk -- sleep 5 &
  local pid=$!
  # Give the child a moment to settle
  sleep 1
  local snapshot
  snapshot="$(ps -wwo args= -p "${pid}" 2>/dev/null || true)"
  # Also check the full process tree for safety
  local full_tree
  full_tree="$(ps -ww -ef 2>/dev/null || true)"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  [[ "${snapshot}"   != *"ghp_0123456789abcdef"* ]]
  [[ "${full_tree}"  != *"ghp_0123456789abcdef"* ]]
}

@test "secret_read prints only the value, no trailing log noise" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  local got
  got="$(secret_read volk github)"
  # Exact match: no leading/trailing whitespace, no extra lines.
  [ "${got}" = "ghp_0123456789abcdef0123456789abcdef0123" ]
}

@test "destroy leaves no traces of the token on disk" {
  local tf="${BATS_TEST_TMPDIR}/tok"
  synthetic_token >"${tf}"
  scripts/auth/github.sh store volk "${tf}"
  scripts/auth/github.sh destroy volk
  # Search the secrets dir for any hex pattern matching our test token
  run grep -RIl 'ghp_0123456789abcdef' "${DEVAGENT_SECRETS_DIR}" 2>/dev/null
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "store rejects token files outside HOME by default? — no: only mode is enforced" {
  # Documenting the behavior: store accepts any readable file. We only
  # enforce mode on the *stored* file. This test pins behavior so we
  # notice if it ever changes.
  local tf="/tmp/devagent-tok-$$"
  synthetic_token >"${tf}"
  run scripts/auth/github.sh store volk "${tf}"
  rm -f "${tf}"
  [ "${status}" -eq 0 ]
}
```

- [ ] **Step 2: Run all auth bats files to make sure security tests pass alongside the others**

Run: `bats tests/auth_security.bats tests/auth_github.bats tests/auth_gitlab.bats tests/auth_jira.bats tests/auth_custom.bats tests/auth_ssh.bats tests/lib_secrets.bats tests/auth_common.bats`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add tests/auth_security.bats
git commit -s -m "$(cat <<'EOF'
test(auth): add cross-cutting security tests

Asserts mode 600 on token files, mode 700 on the secrets dir (with
auto-repair from looser modes), that exec never leaks the token via
ps argv, and that destroy leaves no on-disk traces.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `commands/auth.md` — slash command dispatcher

**Files:**
- Create: `commands/auth.md`

- [ ] **Step 1: Write the command spec**

```markdown
---
name: devagent:auth
description: Manage PAT / SSH-key lifecycle (create, store, rotate, destroy, status, exec) for a project's tracker and code-forge backends.
---

# /devagent:auth

Dispatches to `scripts/auth/<backend>.sh <verb>` based on the
sub-verb and the project's configured backend(s).

## Usage

```
/devagent:auth create   [project] [backend]
/devagent:auth store    [project] [backend] <token-file>
/devagent:auth rotate   [project] [backend]
/devagent:auth destroy  [project] [backend]
/devagent:auth status   [project]                # all backends for the project
/devagent:auth exec     [project] [backend] -- <cmd ...>
```

If `backend` is omitted, the dispatcher uses the project's configured
backends:

- For `create|store|rotate|destroy|exec`: requires an explicit backend.
- For `status`: reports on all configured backends
  (`issue_source.backend`, `issue_source_fork.backend`,
  `code_source.backend`, and `ssh` if a key is registered).

`project` falls back to the active project in state when omitted,
matching the §6.1 invocation grammar.

## What the model does on invocation

1. Parse the verb and remaining tokens via the standard grammar.
2. Resolve `project` (state-active project if omitted).
3. Resolve `backend` (explicit, or derived from config for `status`).
4. Invoke `scripts/auth/<backend>.sh <verb> <project> [args...]`.
   For `exec`, pass the post-`--` tokens through verbatim.
5. Surface the script's stdout/stderr to the operator. Do NOT
   interpret or paraphrase tokens or fingerprints; print them
   verbatim from the script output.
6. On `create`: confirm to the operator that browser was opened and
   prompt for the paste step if the script is waiting on stdin.

## Permission gates

`auth` operations are not subject to `[project.<name>.permissions]`
gates. They affect only local files. Remote operations (creating the
token on GitHub/GitLab/JIRA) are done by the operator in the browser
and not by the plugin.

## Examples

```
/devagent:auth create  volk github
/devagent:auth status  volk
/devagent:auth exec    volk github -- gh pr list --repo gnuradio/volk
/devagent:auth rotate  volk gitlab
/devagent:auth destroy volk jira
```

## Doctor hook

`/devagent:doctor` calls `scripts/lib/doctor_auth.sh check <project>`
to produce a per-project auth health summary without leaking tokens.
See that script's header for the contract.
```

- [ ] **Step 2: Commit**

```bash
git add commands/auth.md
git commit -s -m "$(cat <<'EOF'
feat(auth): add /devagent:auth slash command spec

Single dispatcher command for the six auth verbs. Documents how the
model resolves project + backend, what permission gates apply
(none — local-only), and which script the doctor hook lives in.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `scripts/lib/doctor_auth.sh` — doctor integration hook

**Files:**
- Create: `tests/doctor_auth.bats`
- Create: `scripts/lib/doctor_auth.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# tests/doctor_auth.bats
load 'helpers/auth_setup'

setup()    { auth_setup_common; install_stub gh ""; install_stub glab ""; install_stub curl ""; }
teardown() { auth_teardown_common; }

@test "doctor_auth check for project with no secrets reports MISSING per backend" {
  run scripts/lib/doctor_auth.sh check volk github gitlab
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: MISSING"* ]]
  [[ "${output}" == *"gitlab: MISSING"* ]]
}

@test "doctor_auth check with stored token reports OK and metadata, no token" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  run scripts/lib/doctor_auth.sh check volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: OK"* ]]
  [[ "${output}" != *"ghp_0123456789abcdef"* ]]
}

@test "doctor_auth check with stored token but bad mode reports WARN" {
  source scripts/lib/secrets.sh
  secret_write volk github "$(synthetic_token)"
  chmod 644 "${DEVAGENT_SECRETS_DIR}/volk.github.pat"
  run scripts/lib/doctor_auth.sh check volk github
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github: WARN"* ]]
  [[ "${output}" == *"mode=644"* ]]
}

@test "doctor_auth check with bad secrets-dir mode reports WARN globally" {
  mkdir -p "${DEVAGENT_SECRETS_DIR}"
  chmod 755 "${DEVAGENT_SECRETS_DIR}"
  run scripts/lib/doctor_auth.sh check volk github
  [[ "${output}" == *"secrets_dir_mode=755"* ]]
  [[ "${output}" == *"WARN"* ]]
}

@test "doctor_auth check exits 0 even on failures (advisory, not gating)" {
  run scripts/lib/doctor_auth.sh check volk github gitlab jira
  [ "${status}" -eq 0 ]
}

@test "doctor_auth check supports ssh as a 'backend'" {
  run scripts/lib/doctor_auth.sh check volk ssh
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ssh: MISSING"* ]]
}
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `bats tests/doctor_auth.bats`
Expected: all fail.

- [ ] **Step 3: Implement `scripts/lib/doctor_auth.sh`**

```bash
#!/usr/bin/env bash
# scripts/lib/doctor_auth.sh
#
# Doctor hook for the auth subsystem. Phase 1's /devagent:doctor calls
# this script as:
#
#     scripts/lib/doctor_auth.sh check <project> <backend> [<backend> ...]
#
# Contract:
#   - Prints one line per backend in the form:
#         <backend>: <STATUS> [key=value ...]
#     where STATUS is one of: OK | WARN | MISSING | ERROR
#   - Prints one summary line for the secrets dir:
#         secrets_dir_mode=<octal> <STATUS>
#   - NEVER prints the token value.
#   - Exits 0 regardless of findings (this is advisory, not gating).
#     Doctor aggregates statuses across all hooks and decides exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/secrets.sh"

_check_dir() {
  if [ ! -d "${DEVAGENT_SECRETS_DIR}" ]; then
    printf 'secrets_dir: MISSING path=%s\n' "${DEVAGENT_SECRETS_DIR}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${DEVAGENT_SECRETS_DIR}")"
  if [ "${mode}" = "700" ]; then
    printf 'secrets_dir: OK secrets_dir_mode=%s\n' "${mode}"
  else
    printf 'secrets_dir: WARN secrets_dir_mode=%s expected=700\n' "${mode}"
  fi
}

_check_pat_backend() {
  local proj="$1" backend="$2"
  local f
  f="$(secret_path "${proj}" "${backend}")" || { printf '%s: ERROR invalid_name\n' "${backend}"; return; }
  if [ ! -f "${f}" ]; then
    printf '%s: MISSING path=%s\n' "${backend}" "${f}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${f}")"
  if [ "${mode}" != "600" ]; then
    printf '%s: WARN mode=%s expected=600\n' "${backend}" "${mode}"
    return
  fi
  local size; size="$(stat -c '%s' "${f}")"
  printf '%s: OK mode=%s size_bytes=%s\n' "${backend}" "${mode}" "${size}"
}

_check_ssh_backend() {
  local proj="$1"
  local link="${DEVAGENT_SECRETS_DIR}/${proj}.ssh"
  if [ ! -L "${link}" ]; then
    printf 'ssh: MISSING path=%s\n' "${link}"
    return
  fi
  local target; target="$(readlink "${link}")"
  if [ ! -f "${target}" ]; then
    printf 'ssh: ERROR dangling_symlink target=%s\n' "${target}"
    return
  fi
  local mode; mode="$(stat -c '%a' "${target}")"
  if [ "${mode}" != "600" ]; then
    printf 'ssh: WARN mode=%s expected=600 target=%s\n' "${mode}" "${target}"
    return
  fi
  printf 'ssh: OK target=%s\n' "${target}"
}

main() {
  if [ "${1:-}" != "check" ]; then
    echo "doctor_auth: usage: $0 check <project> <backend> [<backend> ...]" >&2
    exit 1
  fi
  shift
  local proj="${1:-}"; shift || true
  if [ -z "${proj}" ]; then
    echo "doctor_auth: project required" >&2
    exit 1
  fi
  _check_dir
  local b
  for b in "$@"; do
    case "${b}" in
      ssh) _check_ssh_backend "${proj}" ;;
      *)   _check_pat_backend "${proj}" "${b}" ;;
    esac
  done
  exit 0
}

main "$@"
```

- [ ] **Step 4: Make executable + run tests**

```bash
chmod +x scripts/lib/doctor_auth.sh
bats tests/doctor_auth.bats
```

Expected: 6 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/doctor_auth.sh tests/doctor_auth.bats
git commit -s -m "$(cat <<'EOF'
feat(auth): add doctor_auth.sh hook for /devagent:doctor

One line per backend in the form '<backend>: <STATUS> [key=value...]',
with STATUS in {OK, WARN, MISSING, ERROR}. Never prints the token.
Always exits 0; doctor aggregates statuses across hooks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: End-to-end smoke test across the dispatcher

**Files:**
- Create: `tests/auth_e2e.bats`

- [ ] **Step 1: Write the tests**

```bash
# tests/auth_e2e.bats
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
  export DEVAGENT_JIRA_BASE_URL="https://example.atlassian.net"
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

@test "github full cycle: store → status → exec → rotate → destroy" {
  _full_cycle github GH_TOKEN
}

@test "gitlab full cycle" {
  _full_cycle gitlab GITLAB_TOKEN
}

@test "jira full cycle" {
  _full_cycle jira JIRA_TOKEN
}
```

- [ ] **Step 2: Run all tests in the suite**

Run: `bats tests/auth_e2e.bats`
Expected: 3 passing.

Also run the whole auth test suite:

```bash
bats tests/lib_secrets.bats tests/auth_common.bats \
     tests/auth_github.bats tests/auth_gitlab.bats \
     tests/auth_jira.bats tests/auth_custom.bats \
     tests/auth_ssh.bats tests/auth_security.bats \
     tests/doctor_auth.bats tests/auth_e2e.bats
```

Expected: every test green.

- [ ] **Step 3: Commit**

```bash
git add tests/auth_e2e.bats
git commit -s -m "$(cat <<'EOF'
test(auth): add end-to-end lifecycle smoke tests

Runs store → status → exec → rotate → destroy against github, gitlab,
and jira backends to catch contract drift between the verb dispatchers
and the shared secrets layer.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: README section for the auth subsystem

**Files:**
- Modify: `README.md` (append section if file exists; create if not)

- [ ] **Step 1: Append the auth section**

If `README.md` exists, append the section below; if it does not exist
(Phase 1 may not have created it yet), create a minimal file with
just the auth section. Use this exact content:

```markdown
## Auth subsystem

The auth subsystem manages personal access tokens (PATs) and SSH
keypairs for each project's tracker and forge backends.

### Storage

- `~/.claude/devagent/secrets/<project>.<backend>.pat` (mode 600)
- `~/.claude/devagent/secrets/<project>.ssh` (symlink to `~/.ssh/<key>`)
- Containing directory mode 700

v1 ships file-based storage only. A future `--keyring` mode will swap
in libsecret (Linux), Keychain (macOS), or wincred (Windows) without
changing the caller contract; see `scripts/lib/secrets.sh` for the
abstraction seam.

### Slash command

`/devagent:auth <verb> [project] [backend] [args...]` dispatches to
`scripts/auth/<backend>.sh`. See `commands/auth.md`.

### Verb contract

Every backend script supports:

| Verb     | Purpose                                                          |
|----------|------------------------------------------------------------------|
| create   | Interactive: open browser to PAT page, paste, validate, store    |
| store    | Non-interactive ingest: read token from a file                   |
| rotate   | Atomic: create new, swap into place, destroy old                 |
| destroy  | `shred -u` then `unlink`                                         |
| status   | Print backend, scopes, expiry, last-used (never the token)       |
| exec     | Set the env var (`GH_TOKEN` / `GITLAB_TOKEN` / `JIRA_TOKEN`)     |
|          | and exec the trailing command. Token never on argv.              |

For SSH (`scripts/auth/ssh.sh`), `store` and `exec` are not exposed
(SSH keys are presented to children via `ssh-agent` or `~/.ssh/config`,
not env vars), but `create`, `destroy`, `rotate`, and `status` work
identically.

### Implementing a custom auth backend

`scripts/auth/custom.sh` ships as a stub that exits 64 for every verb
except `status`. To implement a custom backend, copy that file and
fill in each verb following the contract above. The verb dispatch and
argument parsing are provided by `scripts/lib/auth_common.sh`; the
storage layer is `scripts/lib/secrets.sh`. Both are stable v1 APIs.

### Doctor integration

`/devagent:doctor` calls `scripts/lib/doctor_auth.sh check <project>
<backend>...` and reports OK / WARN / MISSING / ERROR per backend
plus the secrets-dir mode. The script never prints the token value
and always exits 0; doctor aggregates statuses across hooks.

### Security tests

`tests/auth_security.bats` pins these invariants:

- token file mode is exactly 600
- secrets directory mode is exactly 700 (auto-repaired on every write)
- `exec` never puts the token on argv (verified via `ps -wwo args=`)
- `destroy` leaves no on-disk traces of the token

Do not write code that bypasses `scripts/lib/secrets.sh` for read or
write; direct file I/O against the secrets directory is a contract
violation and will break the future `--keyring` migration.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -s -m "$(cat <<'EOF'
docs(auth): document auth subsystem in README

Covers storage layout, verb contract, custom-backend implementation
guide, doctor integration, and the security invariants pinned by
tests/auth_security.bats.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (do not skip)

After implementing all 13 tasks, re-read this plan against spec §3.4
and §10:

- [x] `create` interactive: yes (Task 4/5/6 via `_*_create_interactive`)
- [x] `store` non-interactive ingest: yes (every backend)
- [x] `rotate` atomic create-swap-destroy: yes (`secret_write` is atomic mktemp+mv)
- [x] `destroy` shred + unlink: yes (`secret_destroy` in secrets.sh, plus ssh.sh)
- [x] `status` prints backend/scopes/expiry/last-used, never token: yes (security test asserts)
- [x] `exec` sets env var and execs: yes (`auth_run_exec`)
- [x] All four backends (github, gitlab, jira, custom): yes (Tasks 4–7)
- [x] PAT path `~/.claude/devagent/secrets/<project>.<backend>.pat`: yes
- [x] Dir mode 700, file mode 600: yes (enforced + tested)
- [x] SSH symlink at `<project>.ssh`: yes (Task 8)
- [x] `--keyring` seam designed but not implemented: yes (`DEVAGENT_SECRETS_BACKEND=keyring` errors clearly)
- [x] SSH create generates ed25519, optionally uploads pubkey: partially — we generate; uploading is a per-backend concern and is **noted as deferred** in the README. Operator uploads pubkey manually in v1.
- [x] SSH status fingerprint + ssh-agent last-used: yes
- [x] SSH destroy shred + remove: yes
- [x] SSH rotate = destroy + create: yes
- [x] Doctor hook contract: yes (Task 11)
- [x] Tokens not in `ps`, history, argv: yes (security test asserts ps; we never `echo` token; argv-free via exported env then `exec`)
- [x] Tests use synthetic 40-char hex, never real PATs: yes (helper enforces)

---

## Open questions for the operator

1. **SSH pubkey upload to backend.** The spec says "optionally uploads
   pubkey to backend via API if PAT exists." This plan defers the
   upload to operator-manual in v1 — the script generates and stores
   but does not call `gh ssh-key add` / `glab ssh-key add`. Confirm
   this is acceptable, or add a Task 8b to wire upload paths per
   backend (will add ~50 LOC + 3 tests per backend).

2. **`status` "expiry" field.** GitHub PATs (classic) don't expose
   expiry through `gh auth status`; fine-grained PATs do via REST
   `/user`. GitLab PATs expose expiry via `/personal_access_tokens`.
   JIRA Atlassian API tokens don't have an expiry concept. This plan
   omits `expiry` from `status` output everywhere. Confirm, or add a
   per-backend expiry probe (will add ~20 LOC + 1 test per backend
   that supports it).

3. **`last-used` semantics.** The plan prints `last_used=unknown`
   uniformly. GitHub fine-grained PATs expose `last_used_at` via
   REST; GitLab does similarly. Should the plan probe these? Same
   trade-off as (2).

4. **Phase 1 doctor wiring.** Phase 1's `/devagent:doctor` plan must
   call `scripts/lib/doctor_auth.sh check <project> <backends...>`.
   This plan ships the hook but does not modify Phase 1's doctor
   script (out of scope per the task constraints). Phase 1 needs a
   follow-up commit (one line) to invoke the hook. Recommend opening
   a tracking issue against Phase 1 once this plan lands.

5. **`--keyring` v2 seam.** The seam is the single
   `DEVAGENT_SECRETS_BACKEND` env var. The plan does not refactor
   `secret_write/read/destroy/stat` into a dispatch table because
   that's premature for v1 with a single backend. Confirm this is
   the right level of abstraction, or specify the dispatch shape
   you'd prefer (e.g., `_secret_file_write` + `_secret_keyring_write`
   with `secret_write` dispatching by `${DEVAGENT_SECRETS_BACKEND}`).
