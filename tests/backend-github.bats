#!/usr/bin/env bats

load lib/contract-helpers.bash

setup() {
  BACKEND_NAME="github"
  ISSUE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/github.sh"
  CODE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/github.sh"
  REPO_ARG="foo/bar"
  ISSUE_NUM_OK="42"
  ISSUE_NUM_404="404"
  ISSUE_NUM_401="401"
  MR_URL_OK="https://github.com/foo/bar/pull/7"
  # #90: github.sh uses the gh CLI (not REST), so the REST fixture harness does
  # not apply. Instead we install the verb-aware gh stub: issue/github.sh calls
  # bare `gh` (PATH), code/github.sh calls $DEVAGENT_GH. The stub asserts the
  # subcommand+flags, so a broken gh invocation fails the contract — the
  # regression net for the whole #59 epic.
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "${BATS_TEST_DIRNAME}/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export DEVAGENT_GH="$STUB_BIN/gh"
  export GH_STUB_CASE="standard"
  export GH_TOKEN="dummy-token"
}

teardown() { :; }

@test "[github] fetch produces spec 9.3 shape" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_OK"
  [ "$status" -eq 0 ]
  assert_fetch_shape "$output"
}

# github goes through the gh CLI, not bc_curl's HTTP-status mapping (exit 4/3),
# so a missing/unauthorized issue surfaces as a generic non-zero gh failure.
@test "[github] fetch on 404 fails non-zero" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_404"
  [ "$status" -ne 0 ]
}

@test "[github] fetch on 401 fails non-zero" {
  run "$ISSUE_SCRIPT" fetch "$REPO_ARG" "$ISSUE_NUM_401"
  [ "$status" -ne 0 ]
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
