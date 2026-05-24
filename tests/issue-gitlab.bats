#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/gitlab"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/gitlab.sh"
}

teardown() {
  fixture_stop
}

@test "issue/gitlab.sh fetch emits spec 9.3 markdown" {
  run "$SCRIPT" fetch foo/bar 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"# foo/bar#42 — Sample issue"* ]]
  [[ "$output" == *"- State: opened"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,performance"* ]]
  [[ "$output" == *"- URL: https://gitlab.example/foo/bar/-/issues/42"* ]]
  [[ "$output" == *"This is the body of the issue."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" != *"assigned to @x"* ]]
}

@test "issue/gitlab.sh create POSTs issue and prints new iid" {
  body=$(mktemp); echo "body text" > "$body"
  run "$SCRIPT" create foo/bar "New issue" "$body" --label bug --label perf
  [ "$status" -eq 0 ]
  [ "$output" = "99" ]
  rm -f "$body"
  grep -q "POST /api/v4/projects/foo%2Fbar/issues" "$FIXTURE_REQUEST_LOG"
}

@test "issue/gitlab.sh transition PUTs label update" {
  export DEVAGENT_GITLAB_LABELS_IN_PROGRESS="status::in-progress"
  export DEVAGENT_GITLAB_LABEL_NAMESPACE="status::"
  run "$SCRIPT" transition foo/bar 42 in_progress
  [ "$status" -eq 0 ]
  grep -q "PUT /api/v4/projects/foo%2Fbar/issues/42" "$FIXTURE_REQUEST_LOG"
}

@test "issue/gitlab.sh state prints opened" {
  run "$SCRIPT" state foo/bar 42
  [ "$status" -eq 0 ]
  [ "$output" = "opened" ]
}

@test "issue/gitlab.sh comment-list prints spec-shape comments" {
  run "$SCRIPT" comment-list foo/bar 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good to me"* ]]
}

@test "issue/gitlab.sh fetch on 404 exits 4" {
  run "$SCRIPT" fetch foo/bar 404
  [ "$status" -eq 4 ]
}

@test "issue/gitlab.sh fetch on 401 exits 3" {
  run "$SCRIPT" fetch foo/bar 401
  [ "$status" -eq 3 ]
}

@test "issue/gitlab.sh with no args exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "issue/gitlab.sh with unknown verb exits 2" {
  run "$SCRIPT" frobnicate foo/bar 42
  [ "$status" -eq 2 ]
}
