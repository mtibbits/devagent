#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="jira"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/jira.sh"
  FIXTURE_SUBDIR="jira"
  REPO_ARG="PROJ"
  ISSUE_NUM_OK="PROJ-42"
  ISSUE_NUM_404="PROJ-404"
  ISSUE_NUM_401="PROJ-401"
  export JIRA_USER="dummy@example.com"
  export JIRA_TOKEN="dummy-token"
  export DEVAGENT_JIRA_STAGE_IN_PROGRESS="In Progress"
  contract_load_fixtures
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
}

teardown() {
  contract_teardown
}

@test "[jira] fetch produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[jira] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[jira] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[jira] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[jira] comment-list produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[jira] transition exits 0" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[jira] transition is idempotent" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[jira] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[jira] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}
