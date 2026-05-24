#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/jira"
  export JIRA_TOKEN="dummy-token"
  export JIRA_USER="dummy@example.com"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/jira.sh"
}

teardown() {
  fixture_stop
}

@test "issue/jira.sh fetch emits spec 9.3 markdown" {
  run "$SCRIPT" fetch PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"# PROJ#PROJ-42 — Sample JIRA issue"* ]]
  [[ "$output" == *"- State: In Progress"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,performance"* ]]
  [[ "$output" == *"Body of the JIRA issue."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
}

@test "issue/jira.sh create POSTs and prints new key" {
  body=$(mktemp); echo "JIRA body" > "$body"
  export DEVAGENT_JIRA_PROJECT_KEY="PROJ"
  export DEVAGENT_JIRA_ISSUE_TYPE="Task"
  run "$SCRIPT" create PROJ "New issue" "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-99" ]
  rm -f "$body"
  grep -q "POST /rest/api/2/issue" "$FIXTURE_REQUEST_LOG"
}

@test "issue/jira.sh transition POSTs transition id" {
  export DEVAGENT_JIRA_STAGE_IN_PROGRESS="In Progress"
  run "$SCRIPT" transition PROJ PROJ-42 in_progress
  [ "$status" -eq 0 ]
  grep -q "POST /rest/api/2/issue/PROJ-42/transitions" "$FIXTURE_REQUEST_LOG"
  grep -q '"id":"21"' "$FIXTURE_REQUEST_LOG"
}

@test "issue/jira.sh state prints status name" {
  run "$SCRIPT" state PROJ PROJ-42
  [ "$status" -eq 0 ]
  [ "$output" = "In Progress" ]
}

@test "issue/jira.sh comment-list prints spec-shape comments" {
  run "$SCRIPT" comment-list PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}

@test "issue/jira.sh fetch on 404 exits 4" {
  run "$SCRIPT" fetch PROJ PROJ-404
  [ "$status" -eq 4 ]
}

@test "issue/jira.sh fetch on 401 exits 3" {
  run "$SCRIPT" fetch PROJ PROJ-401
  [ "$status" -eq 3 ]
}

@test "issue/jira.sh unknown verb exits 2" {
  run "$SCRIPT" frob
  [ "$status" -eq 2 ]
}
