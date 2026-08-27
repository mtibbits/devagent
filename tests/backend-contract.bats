#!/usr/bin/env bats
# backend-contract.bats — aggregator that runs the per-backend contract
# suites in a known order and prints a one-line summary per backend.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  BATS_DIR="${BATS_TEST_DIRNAME}"
}

run_backend_suite() {
  local backend="$1"
  local file="${BATS_DIR}/backend-${backend}.bats"
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  run bats "$file"
  printf '[contract:%s] %s\n' "$backend" "$status" >&2
  return "$status"
}

@test "contract: github backend" {
  run_backend_suite github
}

@test "contract: gitlab backend" {
  run_backend_suite gitlab
}

@test "contract: jira backend" {
  run_backend_suite jira
}

@test "contract: custom-stub backend" {
  run_backend_suite custom
}
