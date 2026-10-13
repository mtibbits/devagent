#!/usr/bin/env bats
#
# #703 state-list fixture provenance: fixtures/jira/search-*.json are
# DOC-DERIVED, NOT RECORDED (no reachable Jira Cloud site). Their shape follows
# Atlassian's published response example for the enhanced JQL search,
# GET /rest/api/{2,3}/search/jql: {issues: [{expand, id, self, key,
# fields: {status: {statusCategory: {key}}, resolution: {name} | null}}],
# nextPageToken?, isLast}. Records: PROJ-1 done/Done, PROJ-2 done/Won't Do,
# PROJ-3 done/Duplicate, PROJ-4 indeterminate, PROJ-5 new, PROJ-6 done/no
# resolution; page 1 links to page 2 by nextPageToken "CAEaAggD=".
# search-badcategory.json lacks statusCategory.key (the fail-closed control).
# search-loop.json repeats its nextPageToken (the paging-loop control).
# search-undefined.json (one record, NOCAT-8 in Jira's fourth status category
# `undefined`, "No Category") pins that category to `other`.
# search-alt.json (one record, ALT-1 done/Done) serves tests/wbs-tracker.bats's
# DEVAGENT_JIRA_PROJECT_KEY leg.
# Route keys were copied from the fixture server's request log of a real run.

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
  unset DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_PROJECT
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

# --- #703 state-list -------------------------------------------------------

@test "[jira] state-list follows nextPageToken and classifies" {
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  run python3 "${BATS_TEST_DIRNAME}/../scripts/lib/wbs-tracker.py" check < "$BATS_TEST_TMPDIR/list"
  [ "$status" -eq 0 ]
  [ "$output" = "6" ]
  grep -q 'nextPageToken=CAEaAggD%3D' "$FIXTURE_REQUEST_LOG"
  grep -qFx $'PROJ-1\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-2\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-3\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-4\tin_progress' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-5\topen' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-6\tdone' "$BATS_TEST_TMPDIR/list"
  run grep -cE $'^[0-9]+\t' "$BATS_TEST_TMPDIR/list"
  [ "$status" -eq 1 ]
}

@test "[jira] state-list percent-encodes the JQL with %20" {
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > /dev/null
  grep -qF 'GET /rest/api/2/search/jql?jql=project%20%3D%20%22PROJ%22%20ORDER%20BY%20key&fields=status,resolution&maxResults=100' "$FIXTURE_REQUEST_LOG"
}

@test "[jira] state-list maps listed not-planned resolutions only" {
  export DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS="Won't Do"
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-2\tnot_planned' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-3\tdone' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-6\tdone' "$BATS_TEST_TMPDIR/list"
}

@test "[jira] state-list reads issue_workflow.not_planned_resolutions from config" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/devagent"
  printf '%s\n' '[project.testproj]' 'source_dir = "/tmp"' '' \
    '[project.testproj.issue_workflow]' "not_planned_resolutions = [\"Won't Do\", \"Duplicate\"]" \
    > "$HOME/.claude/devagent/config.toml"
  export DEVAGENT_PROJECT=testproj
  "$ISSUE_SCRIPT" state-list "$REPO_ARG" > "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-2\tnot_planned' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-3\tnot_planned' "$BATS_TEST_TMPDIR/list"
  grep -qFx $'PROJ-1\tdone' "$BATS_TEST_TMPDIR/list"
}

@test "[jira] state-list on 401 exits 3" {
  run "$ISSUE_SCRIPT" state-list DENIED
  [ "$status" -eq 3 ]
}

@test "[jira] state-list fails closed on an unrecognised status category" {
  run "$ISSUE_SCRIPT" state-list BAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognised statusCategory  on BAD-7"* ]]
}

@test "[jira] state-list reads the undefined (No Category) status category as other (#703 review)" {
  run "$ISSUE_SCRIPT" state-list NOCAT
  [ "$status" -eq 0 ]
  [ "$output" = $'NOCAT-8\tother' ]
}

@test "[jira] state-list without a repo exits 1, not 2" {
  run "$ISSUE_SCRIPT" state-list
  [ "$status" -eq 1 ]
}

@test "[jira] state-list fails closed on a repeated nextPageToken (#703 review)" {
  run timeout 60 "$ISSUE_SCRIPT" state-list LOOP
  [ "$status" -ne 124 ]
  [ "$status" -eq 5 ]
  [[ "$output" == *"nextPageToken repeated"* ]]
}
