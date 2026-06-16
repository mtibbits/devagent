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

@test "issue/jira.sh fetch pages through ALL comments via startAt (#137)" {
  # Jira reports .total but caps the body; the fix must page until total reached.
  tmpfix="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/fixtures/jira/issue.json" "$tmpfix/"
  python3 - "$tmpfix" <<'PY'
import json, os, sys
d = sys.argv[1]
def page(rng):
    return [{"author": {"name": "u%d" % i, "displayName": "U %d" % i},
             "created": "2026-05-12T00:00:00.000+0000", "body": "c%d" % i} for i in rng]
# total = 102; page 1 returns 100, page 2 returns the last 2.
open(os.path.join(d, "c1.json"), "w").write(json.dumps({"total": 102, "startAt": 0, "maxResults": 100, "comments": page(range(100))}))
open(os.path.join(d, "c2.json"), "w").write(json.dumps({"total": 102, "startAt": 100, "maxResults": 100, "comments": page(range(100, 102))}))
routes = {
    "GET /rest/api/2/issue/PROJ-42": {"status": 200, "body_file": "issue.json"},
    "GET /rest/api/2/issue/PROJ-42/comment?startAt=0&maxResults=100": {"status": 200, "body_file": "c1.json"},
    "GET /rest/api/2/issue/PROJ-42/comment?startAt=100&maxResults=100": {"status": 200, "body_file": "c2.json"},
}
open(os.path.join(d, "routes.json"), "w").write(json.dumps(routes))
PY
  fixture_stop
  fixture_start "$tmpfix"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
  run "$SCRIPT" fetch PROJ PROJ-42
  [ "$status" -eq 0 ]
  # Header equals the actual number of comments emitted (102), and the body holds them.
  [[ "$output" == *"## Comments (102)"* ]]
  grep -q "GET /rest/api/2/issue/PROJ-42/comment?startAt=100&maxResults=100" "$FIXTURE_REQUEST_LOG"
  rm -rf "$tmpfix"
}
