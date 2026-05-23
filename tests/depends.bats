#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "depends.sh: <A> on <B> records edge" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "recorded"
  state_file="${DEVAGENT_STATE_DIR}/${DEVAGENT_TEST_PROJECT}.depends.toml"
  grep -q '\[Issue-100\]' "${state_file}"
}

@test "depends.sh list prints graph" {
  bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-101"
}

@test "depends.sh rejects cycle with non-zero exit and message" {
  bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-101 on Issue-100
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cycle"
}

@test "depends.sh usage on missing args" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage"
}
