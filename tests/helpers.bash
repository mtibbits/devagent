# tests/helpers.bash — shared bats setup for capture-family tests
# shellcheck shell=bash

# REPO_ROOT is the devAgent plugin checkout.
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "${BASH_SOURCE[0]}")/lib/hermetic-env.bash"

# Create a clean temp devdoc tree for each test.
setup_tmp_devdoc() {
  export TMP_DEVDOC
  TMP_DEVDOC="$(mktemp -d -t devagent-devdoc.XXXXXX)"
  mkdir -p "${TMP_DEVDOC}/Captures"
  mkdir -p "${TMP_DEVDOC}/templates"
  # #106 (F12): redirect HOME to a throwaway tree so any capture script that falls
  # back to paths.sh defaults ($HOME/.claude/devagent) can never touch real user
  # state under test. Defensive — current scripts receive their dirs explicitly.
  export TMP_HOME
  TMP_HOME="$(mktemp -d -t devagent-home.XXXXXX)"
  export HOME="${TMP_HOME}"
}

teardown_tmp_devdoc() {
  if [[ -n "${TMP_DEVDOC:-}" && -d "${TMP_DEVDOC}" ]]; then
    rm -rf "${TMP_DEVDOC}"
  fi
  if [[ -n "${TMP_HOME:-}" && -d "${TMP_HOME}" ]]; then
    rm -rf "${TMP_HOME}"
  fi
}

# Point devagent state at a tmp dir for reap-idempotence tests.
setup_tmp_state() {
  export TMP_STATE
  TMP_STATE="$(mktemp -d -t devagent-state.XXXXXX)"
  export DEVAGENT_STATE_DIR="${TMP_STATE}"
}

teardown_tmp_state() {
  if [[ -n "${TMP_STATE:-}" && -d "${TMP_STATE}" ]]; then
    rm -rf "${TMP_STATE}"
  fi
}

# Force a deterministic date for slug generation.
freeze_date() {
  export DEVAGENT_DATE_OVERRIDE="${1:-2026-05-19}"
}

# Assert a file exists and matches a grep pattern.
assert_file_grep() {
  local file="$1" pattern="$2"
  [[ -f "${file}" ]] || { echo "missing: ${file}"; return 1; }
  grep -qE "${pattern}" "${file}" || {
    echo "pattern not found: ${pattern}"
    echo "--- file contents ---"
    cat "${file}"
    return 1
  }
}
