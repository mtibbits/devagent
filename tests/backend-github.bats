#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="github"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/github.sh"
  CODE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/github.sh"
  FIXTURE_SUBDIR="github"
  REPO_ARG="foo/bar"
  ISSUE_NUM_OK="42"
  ISSUE_NUM_404="404"
  ISSUE_NUM_401="401"
  MR_URL_OK="https://github.com/foo/bar/pull/7"
  # github.sh uses the gh CLI exclusively (not REST), so DEVAGENT_GITHUB_API
  # has no effect today. Pointing the contract harness at a fixture HTTP
  # server would require either (a) extending github.sh with a REST path
  # alongside the gh path, or (b) building a comprehensive gh stub that
  # responds to every verb's JSON shape. Both are real work; for now we
  # skip the contract suite for github. tests/issue-github.bats already
  # exercises the gh-stub path for the verbs we have today.
  if [ ! -d "${BATS_TEST_DIRNAME}/fixtures/github" ]; then
    skip "github backend has no REST path; uses gh CLI. See tests/issue-github.bats."
  fi
  export GH_TOKEN="dummy-token"
  contract_load_fixtures
  export DEVAGENT_GITHUB_API="$FIXTURE_URL"
}

teardown() {
  contract_teardown
}

@test "[github] fetch produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

@test "[github] fetch on 404 exits 4" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -eq 4 ]
}

@test "[github] fetch on 401 exits 3" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -eq 3 ]
}

@test "[github] state prints a state token" {
  run "$ISSUE_SCRIPT" state "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[github] comment-list produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" comment-list "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}

@test "[github] transition exits 0 (label-based per spec 9.1)" {
  export DEVAGENT_PROJECT="contract-test"
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[github] transition is idempotent" {
  export DEVAGENT_PROJECT="contract-test"
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
  run "$ISSUE_SCRIPT" transition "$REPO_ARG" "$ISSUE_NUM_OK" in_progress
  [ "$status" -eq 0 ]
}

@test "[github] no args exits 2" {
  run "$ISSUE_SCRIPT"
  [ "$status" -eq 2 ]
}

@test "[github] unknown verb exits 2" {
  run "$ISSUE_SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "[github] code mr-state recognized values" {
  run "$CODE_SCRIPT" mr-state "$MR_URL_OK"
  [ "$status" -eq 0 ]
  case "$output" in
    open|merged|closed|draft) ;;
    *) printf 'unexpected mr-state output: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "[github] code mr-comments produces spec shape" {
  run "$CODE_SCRIPT" mr-comments "$MR_URL_OK"
  [ "$status" -eq 0 ]
  assert_comment_list_shape "$output"
}
