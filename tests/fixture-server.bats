#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  # Use a private throwaway dir so we don't clobber the real jira/ fixtures
  # this plan ships in tests/fixtures/jira/.
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/fxsrv-fixtures"
  mkdir -p "$FIXTURE_DIR"
  cat > "$FIXTURE_DIR/routes.json" <<'JSON'
{
  "GET /rest/api/2/issue/PROJ-1": {"status": 200, "body_file": "issue.json"},
  "GET /rest/api/2/issue/MISSING": {"status": 404, "body": "{\"errorMessages\":[\"Issue Does Not Exist\"]}"},
  "GET /rest/api/2/issue/UNAUTH":  {"status": 401, "body": "{\"errorMessages\":[\"Unauthorized\"]}"}
}
JSON
  cat > "$FIXTURE_DIR/issue.json" <<'JSON'
{"key":"PROJ-1","fields":{"summary":"Hi","status":{"name":"Open"}}}
JSON
  fixture_start "$FIXTURE_DIR"
}

teardown() {
  fixture_stop
}

@test "fixture server serves 200 with body_file" {
  run curl -s -o - -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/PROJ-1"
  [[ "$output" == *"PROJ-1"* ]]
  [[ "$output" == *"200" ]]
}

@test "fixture server serves 404" {
  run curl -s -o /dev/null -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/MISSING"
  [ "$output" = "404" ]
}

@test "fixture server serves 401" {
  run curl -s -o /dev/null -w '%{http_code}' "$FIXTURE_URL/rest/api/2/issue/UNAUTH"
  [ "$output" = "401" ]
}

@test "fixture server records POST requests" {
  curl -s -o /dev/null -X POST -d '{"x":1}' "$FIXTURE_URL/anything"
  run cat "$FIXTURE_REQUEST_LOG"
  [[ "$output" == *"POST /anything"* ]]
  [[ "$output" == *'{"x":1}'* ]]
}
