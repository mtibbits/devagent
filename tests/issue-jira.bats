#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/jira"
  export JIRA_TOKEN="dummy-token"
  export JIRA_USER="dummy@example.com"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/jira.sh"
  # #710: the skeleton's config shape — issue_workflow names a status on JIRA.
  export DA_HOME="$BATS_TEST_TMPDIR/da"
  mkdir -p "$DA_HOME"
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.testproj.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
TOML
}

teardown() {
  fixture_stop
}

# _requests: the request log without the fixture server's own startup probe.
_requests() { grep -v '^GET /__ping__' "$FIXTURE_REQUEST_LOG" || true; }

@test "issue/jira.sh fetch emits spec 9.3 markdown" {
  run "$SCRIPT" fetch PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"# PROJ#PROJ-42 — Sample JIRA issue"* ]]
  [[ "$output" == *"- State: In Progress"* ]]
  # #139: Cloud user objects have no .name — author comes from displayName.
  [[ "$output" == *"- Author: @Alice"* ]]
  [[ "$output" == *"- Labels: bug,performance"* ]]
  [[ "$output" == *"Body of the JIRA issue."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @Reviewer · 2026-05-12"* ]]
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

@test "transition on_draft_start: an issue already In Progress gets no POST (#710)" {
  run "$SCRIPT" transition PROJ PROJ-42 on_draft_start --project testproj
  [ "$status" -eq 0 ]
  grep -q $'^GET /rest/api/2/issue/PROJ-42\t' "$FIXTURE_REQUEST_LOG"
  run grep -c '^POST ' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition on_ship|on_merge POSTs the mapped id (#710)" {
  run "$SCRIPT" transition PROJ PROJ-42 on_ship --project testproj
  [ "$status" -eq 0 ]
  grep -qxF $'POST /rest/api/2/issue/PROJ-42/transitions\t{"transition":{"id":"31"}}' "$FIXTURE_REQUEST_LOG"
  : > "$FIXTURE_REQUEST_LOG"
  run "$SCRIPT" transition PROJ PROJ-42 on_merge --project testproj
  [ "$status" -eq 0 ]
  grep -qxF $'POST /rest/api/2/issue/PROJ-42/transitions\t{"transition":{"id":"41"}}' "$FIXTURE_REQUEST_LOG"
}

@test "transition without a mapping exits 0 with one warning, never 2 (#710)" {
  run "$SCRIPT" transition PROJ PROJ-42 on_ship --project other
  [ "$status" -eq 0 ]
  [ "$output" = "jira.sh: no tracker state mapped for 'on_ship' (project other); transition skipped" ]
  [ -z "$(_requests)" ]
}

@test "transition to an unavailable status exits 4 naming it (#710)" {
  export DEVAGENT_JIRA_STAGE_ON_SHIP="Blocked"
  run "$SCRIPT" transition PROJ PROJ-42 on_ship --project testproj
  [ "$status" -eq 4 ]
  [[ "$output" == *"jira.sh: no transition to status 'Blocked' (on_ship) from 'In Progress' on PROJ-42"* ]]
  run grep -c '^POST ' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: a 403 on the POST exits 3 (#710)" {
  run "$SCRIPT" transition PROJ PROJ-43 on_ship --project testproj
  [ "$status" -eq 3 ]
  grep -qxF $'POST /rest/api/2/issue/PROJ-43/transitions\t{"transition":{"id":"31"}}' "$FIXTURE_REQUEST_LOG"
}

@test "transition: a bad --project or a missing positional exits 2 (#710)" {
  # mapped, so only the argument refusal (not a missing mapping) can exit 2
  export DEVAGENT_JIRA_STAGE_ON_SHIP="In Review"
  run "$SCRIPT" transition PROJ PROJ-42 on_ship --project
  [ "$status" -eq 2 ]
  run "$SCRIPT" transition PROJ PROJ-42 on_ship --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" transition PROJ PROJ-42
  [ "$status" -eq 2 ]
  [ -z "$(_requests)" ]
}

@test "state-exists: 0 known, 4 unknown (#710)" {
  run "$SCRIPT" state-exists PROJ "In Review"
  [ "$status" -eq 0 ]
  grep -q '^GET /rest/api/2/status/In%20Review' "$FIXTURE_REQUEST_LOG"
  run "$SCRIPT" state-exists PROJ "Blocked"
  [ "$status" -eq 4 ]
  run "$SCRIPT" state-exists PROJ
  [ "$status" -eq 2 ]
}

@test "state-exists: a status 404 from a site that 404s /myself too is undetermined, not absent (#710)" {
  # a wrong DEVAGENT_JIRA_BASE context path 404s every resource
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL/wrong-context"
  run "$SCRIPT" state-exists PROJ "In Review"
  [ "$status" -eq 1 ]
  grep -q '^GET /wrong-context/rest/api/2/myself' "$FIXTURE_REQUEST_LOG"
}

@test "issue/jira.sh state prints status name" {
  run "$SCRIPT" state PROJ PROJ-42
  [ "$status" -eq 0 ]
  [ "$output" = "In Progress" ]
}

@test "issue/jira.sh comment-list prints spec-shape comments" {
  run "$SCRIPT" comment-list PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @Reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}

@test "issue/jira.sh comment authors fall back displayName→unknown, never @null (#139)" {
  tmpfix="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/fixtures/jira/issue.json" "$tmpfix/"
  python3 - "$tmpfix" <<'PY'
import json, os, sys
d = sys.argv[1]
comments = {"total": 2, "startAt": 0, "maxResults": 100, "comments": [
    {"author": {"accountId": "acc-1", "displayName": "Cloud User"}, "created": "2026-05-12T00:00:00.000+0000", "body": "from cloud"},
    {"author": {"accountId": "acc-2"}, "created": "2026-05-12T00:00:00.000+0000", "body": "anonymous"},
]}
open(os.path.join(d, "comments.json"), "w").write(json.dumps(comments))
routes = {
    "GET /rest/api/2/issue/PROJ-42": {"status": 200, "body_file": "issue.json"},
    "GET /rest/api/2/issue/PROJ-42/comment?startAt=0&maxResults=100": {"status": 200, "body_file": "comments.json"},
}
open(os.path.join(d, "routes.json"), "w").write(json.dumps(routes))
PY
  fixture_stop
  fixture_start "$tmpfix"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL"
  run "$SCRIPT" fetch PROJ PROJ-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @Cloud User · 2026-05-12"* ]]   # displayName, not null
  [[ "$output" == *"### @unknown · 2026-05-12"* ]]       # neither field → unknown
  [[ "$output" != *"@null"* ]]
  rm -rf "$tmpfix"
}

@test "issue/jira.sh fetch on 404 exits 4" {
  run "$SCRIPT" fetch PROJ PROJ-404
  [ "$status" -eq 4 ]
}

@test "issue/jira.sh fetch on 401 exits 3" {
  run "$SCRIPT" fetch PROJ PROJ-401
  [ "$status" -eq 3 ]
}

@test "issue/jira.sh fetch surfaces the API error body on failure (#138)" {
  run "$SCRIPT" fetch PROJ PROJ-401
  [ "$status" -eq 3 ]
  [[ "$output" == *"Unauthorized"* ]]
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

# #774: bc_jira_paginate fails closed on a 2xx page that is not a comment page,
# and stops a walk that repeats a page. fixtures/jira/comments-full.json (total
# 1000, 100 comments) is served for both startAt=0 and startAt=100 of PROJ-REPEAT;
# it was generated with
#   jq -cn '{startAt: 0, maxResults: 100, total: 1000, comments: [range(100) | {id: (. + 1 | tostring), author: {displayName: "U"}, created: "2026-05-12T00:00:00.000+0000", body: "c"}]}'
@test "issue/jira.sh comment-list fails closed on a 2xx HTML comment page (#774)" {
  run timeout 60 "$SCRIPT" comment-list PROJ PROJ-HTML
  [ "$status" -ne 124 ]
  [ "$status" -eq 5 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=0 of ${FIXTURE_URL}/rest/api/2/issue/PROJ-HTML/comment lacks a .comments array"* ]]
}

@test "issue/jira.sh comment-list fails closed on a 2xx JSON object without comments (#774)" {
  run timeout 60 "$SCRIPT" comment-list PROJ PROJ-NOCOMMENTS
  [ "$status" -eq 5 ]
  [[ "$output" != *"## Comments (0)"* ]]
  [[ "$output" == *"bc_jira_paginate: page at startAt=0 of ${FIXTURE_URL}/rest/api/2/issue/PROJ-NOCOMMENTS/comment lacks a .comments array"* ]]
}

@test "issue/jira.sh comment-list and fetch exit 5, not 6, on a repeated comment page (#774)" {
  run timeout 60 "$SCRIPT" comment-list PROJ PROJ-REPEAT
  [ "$status" -eq 5 ]
  [[ "$output" == *"repeats the page at startAt=0"* ]]
  [ "$(grep -cF 'GET /rest/api/2/issue/PROJ-REPEAT/comment?startAt=' "$FIXTURE_REQUEST_LOG")" -eq 2 ]
  : > "$FIXTURE_REQUEST_LOG"
  run timeout 60 "$SCRIPT" fetch PROJ PROJ-REPEAT
  [ "$status" -eq 5 ]
  [[ "$output" == *"repeats the page at startAt=0"* ]]
}
