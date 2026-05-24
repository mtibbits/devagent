#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="gitlab"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/gitlab.sh"
  CODE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/gitlab.sh"
  FIXTURE_SUBDIR="gitlab"
  REPO_ARG="foo/bar"
  ISSUE_NUM_OK="42"
  ISSUE_NUM_404="404"
  ISSUE_NUM_401="401"
  MR_URL_OK="https://gitlab.example/foo/bar/-/merge_requests/7"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_LABELS_IN_PROGRESS="status::in-progress"
  export DEVAGENT_GITLAB_LABEL_NAMESPACE="status::"
  contract_load_fixtures
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
}

teardown() {
  contract_teardown
}

@test "[gitlab] fetch produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[gitlab] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[gitlab] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[gitlab] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[gitlab] comment-list produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[gitlab] transition exits 0" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[gitlab] transition is idempotent" {
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[gitlab] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[gitlab] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "[gitlab] code mr-state recognized values" {
  run "$CODE_SCRIPT" mr-state "$MR_URL_OK"
  [ "$status" -eq 0 ]
  case "$output" in
    open|merged|closed|draft) ;;
    *) printf 'unexpected mr-state output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "[gitlab] code mr-comments produces spec shape" {
  run "$CODE_SCRIPT" mr-comments "$MR_URL_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}
