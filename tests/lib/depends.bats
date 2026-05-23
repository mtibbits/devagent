#!/usr/bin/env bats

load _helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "depends_add writes a single edge to state file" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  [ "$status" -eq 0 ]

  state_file="${DEVAGENT_STATE_DIR}/${DEVAGENT_TEST_PROJECT}.depends.toml"
  [ -f "${state_file}" ]
  grep -q '\[Issue-100\]' "${state_file}"
  grep -q 'depends_on = \["Issue-101"\]' "${state_file}"
}

@test "depends_add is idempotent for repeated edges" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  count="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100" | wc -w)"
  [ "${count}" -eq 1 ]
}

@test "depends_add refuses self-dependency" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-100"
  [ "$status" -eq 3 ]
}

@test "depends_add appends a second distinct edge" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  deps="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100")"
  echo "${deps}" | grep -q "Issue-101"
  echo "${deps}" | grep -q "Issue-102"
}
