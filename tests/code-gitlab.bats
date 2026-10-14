#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # #704: run --separate-stderr (bc_curl's error body has no newline)

load lib/fixture-server.sh

setup() {
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/gitlab"
  export GITLAB_TOKEN="dummy-token"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4"
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code/gitlab.sh"
  TMPGIT="$(mktemp -d)"
  ( cd "$TMPGIT" && git init -q && git -c user.email=t@x -c user.name=t commit --allow-empty -q -m init )
  PUSHED_REMOTE="$(mktemp -d)"
  git -C "$PUSHED_REMOTE" init -q --bare
  git -C "$TMPGIT" remote add origin "$PUSHED_REMOTE"
}

teardown() {
  fixture_stop
  rm -rf "$TMPGIT" "$PUSHED_REMOTE"
}

@test "code/gitlab.sh push-branch pushes to remote" {
  ( cd "$TMPGIT" && git checkout -q -b feat/x && git -c user.email=t@x -c user.name=t commit --allow-empty -q -m x )
  ( cd "$TMPGIT" && "$SCRIPT" push-branch origin feat/x )
  git -C "$PUSHED_REMOTE" rev-parse feat/x >/dev/null
}

@test "code/gitlab.sh create-mr POSTs and prints URL" {
  body=$(mktemp); echo "MR body" > "$body"
  run "$SCRIPT" create-mr foo/bar "Sample MR" "$body" feat/x main
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://gitlab.example/foo/bar/-/merge_requests/12"* ]]
  rm -f "$body"
  grep -q "POST /api/v4/projects/foo%2Fbar/merge_requests" "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh create-mr dies on a cross-project (owner:branch) head, no POST (#88 B1)" {
  body=$(mktemp); echo "MR body" > "$body"
  run "$SCRIPT" create-mr foo/bar "Sample MR" "$body" me:feat/x main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported"* ]]
  rm -f "$body"
  # must die BEFORE posting — no merge_requests POST hit the fixture server
  run grep -q "POST /api/v4/projects/.*/merge_requests" "$FIXTURE_REQUEST_LOG"
  [ "$status" -ne 0 ]
}

@test "code/gitlab.sh create-mr --draft sets draft prefix" {
  body=$(mktemp); echo "MR body" > "$body"
  run "$SCRIPT" create-mr foo/bar "Sample MR" "$body" feat/x main --draft
  [ "$status" -eq 0 ]
  rm -f "$body"
  grep -q '"title":"Draft: Sample MR"' "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh mr-state opened maps to open" {
  run "$SCRIPT" mr-state "https://gitlab.example/foo/bar/-/merge_requests/7"
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

@test "code/gitlab.sh mr-comments prints spec-shape markdown" {
  run "$SCRIPT" mr-comments "https://gitlab.example/foo/bar/-/merge_requests/7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"needs a test"* ]]
}

@test "code/gitlab.sh merge-mr PUTs merge" {
  run "$SCRIPT" merge-mr "https://gitlab.example/foo/bar/-/merge_requests/7" --method squash
  [ "$status" -eq 0 ]
  grep -q "PUT /api/v4/projects/foo%2Fbar/merge_requests/7/merge" "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh merge-mr defaults to squash, matching github (C18)" {
  run "$SCRIPT" merge-mr "https://gitlab.example/foo/bar/-/merge_requests/7"
  [ "$status" -eq 0 ]
  grep -q "PUT /api/v4/projects/foo%2Fbar/merge_requests/7/merge" "$FIXTURE_REQUEST_LOG"
  # default method is squash (not a plain merge); payload carries squash:true
  grep -q '"squash":true' "$FIXTURE_REQUEST_LOG"
}

@test "code/gitlab.sh with unknown verb exits 2" {
  run "$SCRIPT" wat
  [ "$status" -eq 2 ]
}

# --- issue-mrs (#704) --------------------------------------------------------
# Routes in fixtures/gitlab/routes.json; provenance: related-mrs-README.md.

_related_calls() {
  grep -c '/related_merge_requests' "$FIXTURE_REQUEST_LOG" || true
}

@test "issue-mrs links \"Closes #6, #7 and grp/sub/bar#8\"; mention-only does not (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 6 7
  [ "$status" -eq 0 ]
  [ "$output" = $'issue\t6\tmerged\nmr\t6\tfoo/bar!21\tmerged\t2026-10-07T03:24:16Z\t2026-10-09T00:44:35Z\nissue\t7\tmerged\nmr\t7\tfoo/bar!21\tmerged\t2026-10-07T03:24:16Z\t2026-10-09T00:44:35Z' ]
  [[ "$output" != *'!99'* ]]
}

@test "issue-mrs aggregation incl. draft and locked (#704)" {
  local issues
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 1 2 3 4 13 10
  [ "$status" -eq 0 ]
  issues="$(grep '^issue' <<<"$output")"
  [ "$issues" = $'issue\t1\topen\nissue\t2\tdraft\nissue\t3\tmerged\nissue\t4\tnone\nissue\t13\tnone\nissue\t10\topen' ]
  grep -qxF $'mr\t2\tfoo/bar!41\tdraft\t2026-07-01T00:00:01Z\t-' <<<"$output"
  grep -qxF $'mr\t13\tfoo/bar!61\tclosed\t2026-07-01T00:00:01Z\t-' <<<"$output"
}

@test "issue-mrs makes one GET per id (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 1 2 3 4 13 10
  [ "$status" -eq 0 ]
  [ "$(_related_calls)" -eq 6 ]
}

@test "404 is missing, 401 exits 3, an HTML page exits 5, a page of 100 exits 5 (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 6 404
  [ "$status" -eq 0 ]
  grep -qxF $'issue\t404\tmissing' <<<"$output"
  grep -qxF $'issue\t6\tmerged' <<<"$output"
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 401
  [ "$status" -eq 3 ]
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 501
  [ "$status" -eq 5 ]
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 12
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'issue 12 has 100+ related MRs (cap)'* ]]
}

@test "an unreadable project aborts instead of N missing (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/hidden 6 7
  [ "$status" -eq 1 ]
  [[ "$output" != *missing* ]]
  [ "$(grep -c $'^GET /api/v4/projects/foo%2Fhidden\t' "$FIXTURE_REQUEST_LOG")" -eq 1 ]
}

@test "a fork-project MR \"Closes #5\" links me/bar 5 only (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs me/bar 5
  [ "$status" -eq 0 ]
  [ "$output" = $'issue\t5\topen\nmr\t5\tme/bar!3\topen\t2026-08-01T12:00:00Z\t-' ]
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 5
  [ "$status" -eq 0 ]
  [ "$output" = $'issue\t5\tnone' ]
}

@test "issue-mrs timestamps normalise .575Z (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 6
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t2026-10-07T03:24:16Z\t2026-10-09T00:44:35Z'* ]]
  [[ "$output" != *'.575'* ]]
}

@test "an unrecognised MR state exits 5 (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 11
  [ "$status" -eq 5 ]
}

@test "issue-mrs output passes mr-link.py check (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 1 2 3 4 13 10 6 404
  [ "$status" -eq 0 ]
  run python3 "${BATS_TEST_DIRNAME}/../scripts/lib/mr-link.py" check 1 2 3 4 13 10 6 404 <<<"$output"
  [ "$status" -eq 0 ]
  [ "$output" = 8 ]
}

@test "issue-mrs rejects a non-numeric id with exit 1 and no call (#704)" {
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar 6 x7
  [ "$status" -eq 1 ]
  run --separate-stderr "$SCRIPT" issue-mrs foo/bar
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_related_calls)" -eq 0 ]
}
