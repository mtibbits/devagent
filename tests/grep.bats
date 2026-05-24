#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "grep finds keyword across issue.md and imPlan.md" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
  echo "$output" | grep -q "Issue-100/imPlan.md"
}

@test "grep does NOT search Captures by default" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Captures/"
}

@test "grep --captures includes Captures" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" --captures FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Captures/"
}

@test "grep -i passes through case-insensitive" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -i foobar
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
}

@test "grep -l prints only filenames" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -l FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "issue.md"
  ! echo "$output" | grep -q "FOOBAR"
}

@test "grep prints output in <issue-dir>:<file>:<line>: form" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[^:]*Issue-100/issue\.md:[0-9]+:'
}

@test "grep exits 1 when pattern not found, 2 on usage error" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" ZZZ_NO_MATCH_ZZZ
  [ "$status" -eq 1 ]

  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh"
  [ "$status" -eq 2 ]
}
