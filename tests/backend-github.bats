#!/usr/bin/env bats
#
# #703 state-list fixture provenance: tests/fixtures/issue-github/state-list.json
# was recorded 2026-10-12 with gh 2.95.0 from the public repo mtibbits/devagent:
#   gh issue list --repo mtibbits/devagent --state all --limit 62 \
#     --json number,state,stateReason,labels
# 62 records (59 OPEN, 3 CLOSED/COMPLETED as recorded). Edits, so every class
# is covered (an edit to a capture is a provenance event):
#   #756 OPEN       + label "in progress"      (default in-progress label)
#   #754 OPEN       + label "status: wip"      (the config/env override label)
#   #701 CLOSED     stateReason COMPLETED -> NOT_PLANNED
#   #700 CLOSED     stateReason COMPLETED -> DUPLICATE
#   #692 OPEN -> CLOSED with stateReason ""    (closed, no known reason)
# Added labels carry a placeholder id/color. Nothing else was changed.
# state-list-badstate.json is hand-written: one record with state "MERGED".
# state-list-case.json is hand-written: one OPEN record labelled "In Progress".

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
  export GH_STUB_ISSUE_LIST_FILE="${BATS_TEST_DIRNAME}/fixtures/issue-github/state-list.json"
  unset DEVAGENT_GITHUB_LABEL_IN_PROGRESS DEVAGENT_PROJECT
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

# --- #703 state-list -------------------------------------------------------

@test "[github] state-list emits one valid line per issue past 30" {
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  run python3 "${BATS_TEST_DIRNAME}/../scripts/lib/wbs-tracker.py" check < "$BATS_TEST_TMPDIR/list"
  [ "$status" -eq 0 ]
  local want
  want="$(jq length "$GH_STUB_ISSUE_LIST_FILE" | tr -d '\r')"
  [ "$want" -eq 62 ]
  [ "$output" = "$want" ]
}

@test "[github] state-list asks gh for every issue with the needed fields" {
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh.log"
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 0 ]
  run cat "$GH_STUB_ARGS_LOG"
  [ "$output" = "issue list --repo foo/bar --state all --limit 5000 --json number,state,stateReason,labels" ]
}

@test "[github] state-list classifies each recorded state" {
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'702\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'701\tnot_planned' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'700\tnot_planned' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'692\tother' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'756\tin_progress' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'754\topen' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'753\topen' "$BATS_TEST_TMPDIR/list"
}

@test "[github] state-list honours github_labels.in_progress" {
  export DEVAGENT_GITHUB_LABEL_IN_PROGRESS="status: wip"
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'754\tin_progress' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'756\topen' "$BATS_TEST_TMPDIR/list"
}

@test "[github] state-list honours the github_labels.in_progress config key" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/devagent"
  printf '%s\n' '[project.testproj]' 'source_dir = "/tmp"' '' \
    '[project.testproj.github_labels]' 'in_progress = "status: wip"' \
    > "$HOME/.claude/devagent/config.toml"
  export DEVAGENT_PROJECT=testproj
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'754\tin_progress' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'756\topen' "$BATS_TEST_TMPDIR/list"
}

@test "[github] state-list fails with gh" {
  export GH_STUB_CASE=fail
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 401"* ]]
}

@test "[github] state-list fails closed on an unrecognised state" {
  export GH_STUB_ISSUE_LIST_FILE="${BATS_TEST_DIRNAME}/fixtures/issue-github/state-list-badstate.json"
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognised state MERGED on #9"* ]]
}

@test "[github] state-list without a repo exits 1, not 2" {
  run "$ISSUE_SCRIPT" state-list
  [ "$status" -eq 1 ]
}

@test "[github] state-list matches the in-progress label case-insensitively (#703 review)" {
  # GitHub label names are case-insensitive: "In Progress" is the default label
  export GH_STUB_ISSUE_LIST_FILE="${BATS_TEST_DIRNAME}/fixtures/issue-github/state-list-case.json"
  run "$ISSUE_SCRIPT" state-list "$REPO_ARG"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'11\tin_progress' "$BATS_TEST_TMPDIR/list"
}

# --- #706 issue-list ---------------------------------------------------------
# Fixtures: tests/fixtures/issue-github/issue-list-shaped.json and
# issue-list-graphql/{1,2}.json, written by tests/fixtures/wbs-import/
# make-fixtures.py (provenance in its header).

_il_shaped() { export GH_STUB_ISSUE_LIST_FILE="${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-shaped.json"; }
_il_check()  { python3 "${BATS_TEST_DIRNAME}/../scripts/lib/wbs-import.py" check; }
# _il_graphql: the GraphQL pages, copied so the stub's call counter never
# writes into the committed fixture tree.
_il_graphql() {
  mkdir -p "$BATS_TEST_TMPDIR/gql"
  cp "${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-graphql/"*.json "$BATS_TEST_TMPDIR/gql/"
  export GH_STUB_GRAPHQL_DIR="$BATS_TEST_TMPDIR/gql" GH_STUB_ISSUE_LIST_UNKNOWN_FIELD=1
}

@test "[github] issue-list passes --limit 5000 and yields 62 records" {
  _il_shaped
  "$ISSUE_SCRIPT" issue-list acme/testproj > "$BATS_TEST_TMPDIR/il"
  run _il_check < "$BATS_TEST_TMPDIR/il"
  [ "$status" -eq 0 ]
  [ "$output" = 62 ]
}

@test "[github] issue-list asks gh for every issue with the issue-list fields" {
  _il_shaped
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh.log"
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 0 ]
  run cat "$GH_STUB_ARGS_LOG"
  [ "$output" = "issue list --repo acme/testproj --state all --limit 5000 --json number,title,body,state,stateReason,createdAt,closedAt,milestone,labels,issueType,parent,blockedBy,url" ]
}

@test "[github] issue-list and state-list agree on every (id, class)" {
  _il_shaped
  "$ISSUE_SCRIPT" issue-list acme/testproj | jq -r '"\(.id)\t\(.class)"' | tr -d '\r' | sort > "$BATS_TEST_TMPDIR/a"
  "$ISSUE_SCRIPT" state-list acme/testproj | sort > "$BATS_TEST_TMPDIR/b"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/b")" -eq 62 ]
  cmp "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
}

@test "[github] issue-list falls back to GraphQL on an older gh and yields identical records" {
  _il_shaped
  "$ISSUE_SCRIPT" issue-list acme/testproj > "$BATS_TEST_TMPDIR/primary"
  _il_graphql
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh.log"
  "$ISSUE_SCRIPT" issue-list acme/testproj > "$BATS_TEST_TMPDIR/fallback"
  [ -s "$BATS_TEST_TMPDIR/primary" ]
  cmp "$BATS_TEST_TMPDIR/primary" "$BATS_TEST_TMPDIR/fallback"
  [ "$(cat "$BATS_TEST_TMPDIR/gql/count")" -eq 2 ]
  # the second page asks for the first page's cursor
  grep -qF '[cursor=Y3Vyc29yOjUw]' "$GH_STUB_ARGS_LOG"
}

@test "[github] issue-list GraphQL fallback refuses a repeated cursor" {
  _il_graphql
  # page 2 claims a next page at page 1's cursor again
  jq '.data.repository.issues.pageInfo = {hasNextPage: true, endCursor: "Y3Vyc29yOjUw"}' \
    "$BATS_TEST_TMPDIR/gql/2.json" > "$BATS_TEST_TMPDIR/gql/2.tmp"
  mv "$BATS_TEST_TMPDIR/gql/2.tmp" "$BATS_TEST_TMPDIR/gql/2.json"
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 5 ]
  [[ "$output" == *"cursor"*"repeated"* ]]
}

@test "[github] issue-list GraphQL fallback stops loudly at its page cap" {
  _il_graphql
  local k page
  page="$(jq -c '.data.repository.issues.pageInfo = {hasNextPage: true, endCursor: "@C@"}
    | .data.repository.issues.nodes = []' \
    "${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-graphql/2.json")"
  for k in $(seq 1 101); do
    printf '%s' "${page//@C@/C$k}" > "$BATS_TEST_TMPDIR/gql/$k.json"
  done
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 5 ]
  [[ "$output" == *"truncated"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/gql/count")" -eq 100 ]
}

@test "[github] issue-list at the --limit of 5000 fails closed as truncated" {
  jq '[range(5000) as $i | .[0] | .number = $i + 1]' \
    "${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-shaped.json" > "$BATS_TEST_TMPDIR/big.json"
  export GH_STUB_ISSUE_LIST_FILE="$BATS_TEST_TMPDIR/big.json"
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 5 ]
  [[ "$output" == *"truncated"* ]]
}

@test "[github] issue-list maps native parent, blockedBy and issueType" {
  _il_shaped
  "$ISSUE_SCRIPT" issue-list acme/testproj > "$BATS_TEST_TMPDIR/il"
  run jq -r 'select(.id == "14") | .parent' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = "https://github.com/acme/testproj/issues/2" ]
  run jq -c 'select(.id == "22") | .blocked_by' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = '["https://github.com/acme/testproj/issues/21"]' ]
  # issueType: a named type maps to its name
  jq '(.[] | select(.number == 1) | .issueType) = {"id": "IT_1", "name": "Epic"}' \
    "$GH_STUB_ISSUE_LIST_FILE" > "$BATS_TEST_TMPDIR/typed.json"
  GH_STUB_ISSUE_LIST_FILE="$BATS_TEST_TMPDIR/typed.json" "$ISSUE_SCRIPT" issue-list acme/testproj > "$BATS_TEST_TMPDIR/il"
  run jq -r 'select(.id == "1") | .type' "$BATS_TEST_TMPDIR/il"
  [ "$(printf '%s' "$output" | tr -d '\r')" = Epic ]
}

@test "[github] issue-list fails closed on a record missing parent, blockedBy or issueType" {
  local k
  for k in parent blockedBy issueType; do
    jq --arg k "$k" '(.[0]) |= del(.[$k])' \
      "${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-shaped.json" > "$BATS_TEST_TMPDIR/strip.json"
    GH_STUB_ISSUE_LIST_FILE="$BATS_TEST_TMPDIR/strip.json" run "$ISSUE_SCRIPT" issue-list acme/testproj
    [ "$status" -eq 5 ]
    [[ "$output" == *"$k"* ]]
  done
}

@test "[github] issue-list fails closed on an unrecognised state" {
  jq '(.[0].state) = "MERGED"' \
    "${BATS_TEST_DIRNAME}/fixtures/issue-github/issue-list-shaped.json" > "$BATS_TEST_TMPDIR/bad.json"
  export GH_STUB_ISSUE_LIST_FILE="$BATS_TEST_TMPDIR/bad.json"
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 5 ]
  [[ "$output" == *"unrecognised state MERGED on #1"* ]]
}

@test "[github] issue-list without a repo exits 1, not 2" {
  run "$ISSUE_SCRIPT" issue-list
  [ "$status" -eq 1 ]
}

@test "[github] issue-list fails with gh" {
  _il_shaped
  export GH_STUB_CASE=fail
  run "$ISSUE_SCRIPT" issue-list acme/testproj
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 401"* ]]
}
