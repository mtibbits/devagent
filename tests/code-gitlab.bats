#!/usr/bin/env bats

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
