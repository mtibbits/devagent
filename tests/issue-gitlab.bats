#!/usr/bin/env bats

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/gitlab"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/issue/gitlab.sh"
  # #710: the skeleton's config shape — issue_workflow names a label on GitLab.
  export DA_HOME="$BATS_TEST_TMPDIR/da"
  mkdir -p "$DA_HOME"
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.testproj.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
TOML
}

# _requests: the request log without the fixture server's own startup probe.
_requests() { grep -v '^GET /__ping__' "$FIXTURE_REQUEST_LOG" || true; }

# _put_body <iid>: the body of every PUT to issue <iid>, one per line.
_put_body() {
  awk -F'\t' -v p="PUT /api/v4/projects/foo%2Fbar/issues/$1" '$1 == p { print $2 }' "$FIXTURE_REQUEST_LOG"
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

@test "transition <stage> PUTs the mapped add_labels with matching remove_labels (#710)" {
  run "$SCRIPT" transition foo/bar 43 on_ship --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 43)" = '{"add_labels":"In Review","remove_labels":"In Progress"}' ]
  # the label check is logged before the PUT
  local check put
  check="$(grep -n '^GET /api/v4/projects/foo%2Fbar/labels/In%20Review?include_ancestor_groups=true' "$FIXTURE_REQUEST_LOG" | cut -d: -f1)"
  put="$(grep -n '^PUT /api/v4/projects/foo%2Fbar/issues/43' "$FIXTURE_REQUEST_LOG" | cut -d: -f1)"
  [ "$check" -lt "$put" ]
  : > "$FIXTURE_REQUEST_LOG"
  run "$SCRIPT" transition foo/bar 43 on_merge --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 43)" = '{"add_labels":"Done","remove_labels":"In Progress"}' ]
  # no stage label on issue 42: nothing to remove, so no remove_labels key
  run "$SCRIPT" transition foo/bar 42 on_draft_start --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 42)" = '{"add_labels":"In Progress"}' ]
}

@test "transition checks the label first: missing exits 4, no PUT, no label POST (#710)" {
  export DEVAGENT_GITLAB_LABELS_ON_SHIP="Nope"
  run "$SCRIPT" transition foo/bar 42 on_ship --project testproj
  [ "$status" -eq 4 ]
  [[ "$output" == *"gitlab.sh: label 'Nope' (on_ship) not found on foo/bar or its groups (or the project is not visible to this token); devagent does not create labels — create it or change the mapping"* ]]
  # the label lookup is the first request, and nothing was written
  [ "$(_requests | head -1 | cut -f1)" = 'GET /api/v4/projects/foo%2Fbar/labels/Nope?include_ancestor_groups=true' ]
  run grep -cE '^(PUT|POST) ' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition accepts a group-level label via include_ancestor_groups (#710)" {
  export DEVAGENT_GITLAB_LABELS_ON_SHIP="Group Label"
  run "$SCRIPT" transition foo/bar 42 on_ship --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 42)" = '{"add_labels":"Group Label"}' ]
}

@test "transition: label-check 401 exits 3 with no PUT (#710)" {
  run "$SCRIPT" transition foo/denied 42 on_ship --project testproj
  [ "$status" -eq 3 ]
  run grep -c '^PUT ' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: a 403 on the PUT exits 3 (#710)" {
  run "$SCRIPT" transition foo/bar 44 on_ship --project testproj
  [ "$status" -eq 3 ]
  [ "$(_put_body 44)" = '{"add_labels":"In Review"}' ]
}

@test "transition: an issue already carrying the target gets no PUT (#710)" {
  run "$SCRIPT" transition foo/bar 43 on_draft_start --project testproj
  [ "$status" -eq 0 ]
  grep -q '^GET /api/v4/projects/foo%2Fbar/issues/43' "$FIXTURE_REQUEST_LOG"
  run grep -c '^PUT ' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: the target already present with a stale stage label still PUTs its removal (#710 review)" {
  run "$SCRIPT" transition foo/bar 45 on_ship --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 45)" = '{"add_labels":"In Review","remove_labels":"In Progress"}' ]
}

@test "transition: the retired namespace key and env are not sent (#710)" {
  printf '%s\n' '' '[project.testproj.gitlab_labels]' 'remove_others_in_namespace = "status::"' >> "$DA_HOME/config.toml"
  export DEVAGENT_GITLAB_LABEL_NAMESPACE="status::"
  run "$SCRIPT" transition foo/bar 42 on_ship --project testproj
  [ "$status" -eq 0 ]
  [ "$(_put_body 42)" = '{"add_labels":"In Review"}' ]
  run grep -F 'status::' "$FIXTURE_REQUEST_LOG"
  [ "$status" -eq 1 ]
}

@test "transition: unmapped exits 0 with no request (#710)" {
  run "$SCRIPT" transition foo/bar 42 on_ship --project other
  [ "$status" -eq 0 ]
  [ "$output" = "gitlab.sh: no tracker state mapped for 'on_ship' (project other); transition skipped" ]
  [ -z "$(_requests)" ]
}

@test "transition: a bad --project or a missing positional exits 2 (#710)" {
  run "$SCRIPT" transition foo/bar 42 on_ship --project
  [ "$status" -eq 2 ]
  run "$SCRIPT" transition foo/bar 42 on_ship --project=testproj
  [ "$status" -eq 2 ]
  run "$SCRIPT" transition foo/bar 42
  [ "$status" -eq 2 ]
  [ -z "$(_requests)" ]
}

@test "state-exists: 0 / 4 / 3 (#710)" {
  run "$SCRIPT" state-exists foo/bar "In Review"
  [ "$status" -eq 0 ]
  run "$SCRIPT" state-exists foo/bar "Nope"
  [ "$status" -eq 4 ]
  run "$SCRIPT" state-exists foo/denied "In Review"
  [ "$status" -eq 3 ]
  run "$SCRIPT" state-exists foo/bar
  [ "$status" -eq 2 ]
}

@test "state-exists: a label 404 on a project the token cannot see is undetermined, not absent (#710)" {
  # GitLab answers 404, not 403, for a private project an under-scoped token
  # cannot see, and for a wrong path: the label 404 alone proves nothing.
  run "$SCRIPT" state-exists foo/ghost "In Review"
  [ "$status" -eq 1 ]
  # the project itself was probed
  grep -qF $'GET /api/v4/projects/foo%2Fghost\t' "$FIXTURE_REQUEST_LOG"
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

@test "issue/gitlab.sh fetch surfaces the API error body on failure (#138)" {
  run "$SCRIPT" fetch foo/bar 404
  [ "$status" -eq 4 ]
  # bc_curl must echo the error body (not swallow it) so set -e failures aren't silent.
  [[ "$output" == *"404 Not Found"* ]]
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

@test "issue/gitlab.sh fetch pages through ALL notes, not just page 1 (#137)" {
  # Build a temp fixture: page 1 full (100 notes) → forces a page-2 fetch (2 notes).
  tmpfix="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/fixtures/gitlab/issue.json" "$tmpfix/"
  python3 - "$tmpfix" <<'PY'
import json, os, sys
d = sys.argv[1]
def notes(rng):
    return [{"id": i, "author": {"username": "u%d" % i},
             "created_at": "2026-05-12T00:00:00Z", "body": "c%d" % i,
             "system": False} for i in rng]
open(os.path.join(d, "p1.json"), "w").write(json.dumps(notes(range(100))))
open(os.path.join(d, "p2.json"), "w").write(json.dumps(notes(range(100, 102))))
routes = {
    "GET /api/v4/projects/foo%2Fbar/issues/42": {"status": 200, "body_file": "issue.json"},
    "GET /api/v4/projects/foo%2Fbar/issues/42/notes?per_page=100&page=1": {"status": 200, "body_file": "p1.json"},
    "GET /api/v4/projects/foo%2Fbar/issues/42/notes?per_page=100&page=2": {"status": 200, "body_file": "p2.json"},
}
open(os.path.join(d, "routes.json"), "w").write(json.dumps(routes))
PY
  fixture_stop
  fixture_start "$tmpfix"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  run "$SCRIPT" fetch foo/bar 42
  [ "$status" -eq 0 ]
  # Header counts BOTH pages (100 + 2), not the truncated first page.
  [[ "$output" == *"## Comments (102)"* ]]
  # And the second page was actually requested.
  grep -q "GET /api/v4/projects/foo%2Fbar/issues/42/notes?per_page=100&page=2" "$FIXTURE_REQUEST_LOG"
  rm -rf "$tmpfix"
}
