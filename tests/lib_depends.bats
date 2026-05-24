#!/usr/bin/env bats

load lib/_helpers

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

@test "depends_add rejects A->B when B->A already exists" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-100"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "cycle"
}

@test "depends_add rejects transitive cycle A->B->C->A" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-102" "Issue-100"
  [ "$status" -eq 4 ]
}

@test "depends_graph renders ascii tree" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "└── Issue-102"
}

@test "depends_graph on empty project prints '(no dependencies)'" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no dependencies"
}

@test "depends_ship_preflight: no deps -> exit 0, silent" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "depends_ship_preflight: open dep, non-strict -> warn, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WARNING"
  echo "$output" | grep -q "Issue-101"
}

@test "depends_ship_preflight: open dep, strict -> block, exit 1" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "blocking"
}

@test "depends_ship_preflight: merged dep -> silent, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  mkdir -p "${DEVAGENT_TEST_DEVDOC}/Issue-101"
  touch "${DEVAGENT_TEST_DEVDOC}/Issue-101/.merged"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 0 ]
}
