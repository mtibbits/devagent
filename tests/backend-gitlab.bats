#!/usr/bin/env bats
#
# #703 state-list fixture provenance: fixtures/gitlab/issues-page{1,2}.json are
# generated (103 records, iid 1-103: iid%3==1 closed, iid%3==2 opened +
# status::in-progress, else opened). Each record is a subset of the fields of
# one item recorded 2026-10-12 from the public gitlab.com project 250833:
#   curl 'https://gitlab.com/api/v4/projects/250833/issues?per_page=1'
# (keys kept: id, iid, project_id, title, state, labels [string array],
# closed_at, web_url). issues-locked.json holds one record whose state is
# "locked" (the fail-closed control).

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

# --- #703 state-list -------------------------------------------------------

@test "[gitlab] state-list pages past 100 and classifies" {
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  run python3 "${BATS_TEST_DIRNAME}/../scripts/lib/wbs-tracker.py" check < "$BATS_TEST_TMPDIR/list"
  [ "$status" -eq 0 ]
  [ "$output" = "103" ]
  grep -q 'issues?per_page=100&page=2' "$FIXTURE_REQUEST_LOG"
  grep -qFx $'1\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'101\tin_progress' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'102\topen' "$BATS_TEST_TMPDIR/list"
}

@test "[gitlab] state-list without an in-progress label never says in_progress" {
  unset DEVAGENT_GITLAB_LABELS_IN_PROGRESS DEVAGENT_PROJECT
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'2\topen' "$BATS_TEST_TMPDIR/list"
  run grep -c in_progress "$BATS_TEST_TMPDIR/list"
  [ "$status" -eq 1 ]
}

@test "[gitlab] state-list on 401 exits 3" {
  run "$ISSUE_SCRIPT" state-list foo/denied
  [ "$status" -eq 3 ]
}

@test "[gitlab] state-list fails closed on an unrecognised state" {
  run "$ISSUE_SCRIPT" state-list foo/locked
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognised state locked on #7"* ]]
}

@test "[gitlab] state-list without a repo exits 1, not 2" {
  run "$ISSUE_SCRIPT" state-list
  [ "$status" -eq 1 ]
}

@test "[gitlab] state-list fails closed on a 2xx page that is not JSON (#703 review)" {
  # a login page or proxy answer must not loop forever or read as no issues
  run timeout 60 "$ISSUE_SCRIPT" state-list foo/html
  [ "$status" -ne 124 ]
  [ "$status" -eq 5 ]
}

@test "[gitlab] state-list fails closed on a 2xx JSON object (#703 review)" {
  run timeout 60 "$ISSUE_SCRIPT" state-list foo/object
  [ "$status" -ne 124 ]
  [ "$status" -eq 5 ]
}

# --- #706 issue-list ---------------------------------------------------------
# issues-page{1,2}.json, issues-shaped.json and links-shaped-21.json are
# written by tests/fixtures/wbs-import/make-fixtures.py (provenance in its
# header; the page files keep #703's records and add the issue-list keys).

_il_check() { python3 "${BATS_TEST_DIRNAME}/../scripts/lib/wbs-import.py" check; }

@test "[gitlab] issue-list pages past 100" {
  "$ISSUE_SCRIPT" issue-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/il"
  run _il_check < "$BATS_TEST_TMPDIR/il"
  [ "$status" -eq 0 ]
  [ "$output" = 103 ]
  grep -q 'issues?per_page=100&page=2' "$FIXTURE_REQUEST_LOG"
}

@test "[gitlab] issue-list and state-list agree on every (id, class)" {
  local r
  for r in foo/bar foo/shaped; do
    "$ISSUE_SCRIPT" issue-list "$r" | jq -r '"\(.id)\t\(.class)"' | tr -d '\r' | sort > "$BATS_TEST_TMPDIR/a"
    "$ISSUE_SCRIPT" state-list "$r" | sort > "$BATS_TEST_TMPDIR/b"
    [ "$(wc -l < "$BATS_TEST_TMPDIR/b")" -gt 60 ]
    cmp "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  done
}

@test "[gitlab] issue-list reads blocking links only where counted" {
  "$ISSUE_SCRIPT" issue-list foo/shaped > "$BATS_TEST_TMPDIR/il"
  run _il_check < "$BATS_TEST_TMPDIR/il"
  [ "$output" = 62 ]
  [ "$(grep -c '/links' "$FIXTURE_REQUEST_LOG")" -eq 1 ]
  grep -q 'GET /api/v4/projects/foo%2Fshaped/issues/21/links' "$FIXTURE_REQUEST_LOG"
  run jq -c 'select(.id == "22") | .blocked_by' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = '["https://gitlab.example/foo/shaped/-/issues/21"]' ]
  run jq -c 'select(.id == "21") | .blocked_by' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = '[]' ]
}

@test "[gitlab] issue-list maps the record fields" {
  "$ISSUE_SCRIPT" issue-list foo/shaped > "$BATS_TEST_TMPDIR/il"
  run jq -c 'select(.id == "1") | [.state, .class, .created, .closed, .labels, .type, .parent, .url]' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = '["closed","done","2026-01-03","2026-01-24",["epic"],"issue",null,"https://gitlab.example/foo/shaped/-/issues/1"]' ]
  # a null description is an empty body
  run jq -r 'select(.id == "30") | .body' "$BATS_TEST_TMPDIR/il"
  [ -z "$(printf '%s' "$output" | tr -d '\r')" ]
}

@test "[gitlab] issue-list dates a closed issue with no closed_at by updated_at" {
  "$ISSUE_SCRIPT" issue-list foo/shaped > "$BATS_TEST_TMPDIR/il"
  run jq -c 'select(.id == "35") | [.state, .closed]' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '')" = '["closed","2026-04-01"]' ]
}

@test "[gitlab] issue-list fails closed on a record without created_at" {
  run "$ISSUE_SCRIPT" issue-list foo/nocreated
  [ "$status" -eq 5 ]
  [[ "$output" == *"created_at"* ]]
}

@test "[gitlab] issue-list fails closed on a non-array page" {
  run timeout 60 "$ISSUE_SCRIPT" issue-list foo/html
  [ "$status" -eq 5 ]
  run timeout 60 "$ISSUE_SCRIPT" issue-list foo/object
  [ "$status" -eq 5 ]
}

@test "[gitlab] issue-list on 401 exits 3" {
  run "$ISSUE_SCRIPT" issue-list foo/denied
  [ "$status" -eq 3 ]
}

@test "[gitlab] issue-list without a repo exits 1, not 2" {
  run "$ISSUE_SCRIPT" issue-list
  [ "$status" -eq 1 ]
}
