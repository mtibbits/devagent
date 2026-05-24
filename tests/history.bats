#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "history.sh whole project prints all entries sorted" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-101"
  echo "$output" | grep -q "Issue-102"
}

@test "history.sh issue scoped prints one issue only" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  ! echo "$output" | grep -q "Issue-101"
}

@test "history.sh output format is human-readable" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^2026-05-10 09:00 +Issue-100 +pull: +fetched'
}
