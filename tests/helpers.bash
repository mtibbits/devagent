# tests/helpers.bash — shared bats setup for capture-family tests
# shellcheck shell=bash

# REPO_ROOT is the devAgent plugin checkout.
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Create a clean temp devdoc tree for each test.
setup_tmp_devdoc() {
  export TMP_DEVDOC
  TMP_DEVDOC="$(mktemp -d -t devagent-devdoc.XXXXXX)"
  mkdir -p "${TMP_DEVDOC}/Captures"
  mkdir -p "${TMP_DEVDOC}/templates"
}

teardown_tmp_devdoc() {
  if [[ -n "${TMP_DEVDOC:-}" && -d "${TMP_DEVDOC}" ]]; then
    rm -rf "${TMP_DEVDOC}"
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
