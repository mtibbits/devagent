#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "history_parse_log extracts entries from a checklist file" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_parse_log "${DEVAGENT_TEST_DEVDOC}/Issue-100/checklist.md" "Issue-100"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2026-05-10 09:00|Issue-100|pull|fetched"
  echo "$output" | grep -q "2026-05-10 09:12|Issue-100|draft|imPlan.md written"
}

@test "history_project merges entries across issues, sorted ascending" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_project "${DEVAGENT_TEST_DEVDOC}"
  [ "$status" -eq 0 ]
  first_line="$(echo "$output" | head -n1)"
  echo "${first_line}" | grep -q "2026-05-09"
  echo "${first_line}" | grep -q "Issue-101"
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-102"
}

@test "history_issue returns only one issue's entries" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_issue "${DEVAGENT_TEST_DEVDOC}/Issue-100"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  run grep -q "Issue-101" <<<"$output"
  [ "$status" -ne 0 ]
}
