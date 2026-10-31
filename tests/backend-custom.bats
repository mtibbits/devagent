#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

ISSUE="${BATS_TEST_DIRNAME}/../scripts/issue/custom.sh"
CODE="${BATS_TEST_DIRNAME}/../scripts/code/custom.sh"

assert_not_implemented() {
  local cmd_status="$1" cmd_output="$2"
  [ "$cmd_status" -eq 78 ]
  [[ "$cmd_output" == *"not implemented"* ]]
  [[ "$cmd_output" == *"README"* ]]
}

@test "issue/custom.sh fetch exits 78 with not-implemented message" {
  run "$ISSUE" fetch foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh create exits 78" {
  body=$(mktemp); echo x > "$body"
  run "$ISSUE" create foo/bar "title" "$body"
  rm -f "$body"
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh transition exits 78" {
  run "$ISSUE" transition foo/bar 42 on_draft_start
  assert_not_implemented "$status" "$output"
}

@test "custom.sh transition with a trailing --project still exits 78, not 2 (#710)" {
  # the callers always append --project; a custom backend may ignore it
  run "$ISSUE" transition foo/bar 42 on_ship --project testproj
  assert_not_implemented "$status" "$output"
}

@test "custom.sh state-exists exits 78 (#710)" {
  run "$ISSUE" state-exists foo/bar "In Review"
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh state exits 78" {
  run "$ISSUE" state foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh comment-list exits 78" {
  run "$ISSUE" comment-list foo/bar 42
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh state-list exits 78" {
  run "$ISSUE" state-list foo/bar
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh issue-list exits 78" {
  run "$ISSUE" issue-list foo/bar
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh events exits 78 (#712)" {
  run "$ISSUE" events foo/bar 1
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh events --kinds exits 78 (#712)" {
  run "$ISSUE" events --kinds foo/bar
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh comment-records exits 78 (#712)" {
  run "$ISSUE" comment-records foo/bar 1
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh whoami exits 78 (#712)" {
  run "$ISSUE" whoami foo/bar
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh push-branch exits 78" {
  run "$CODE" push-branch origin feat/x
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh create-mr exits 78" {
  body=$(mktemp); echo x > "$body"
  run "$CODE" create-mr foo/bar "t" "$body" head base
  rm -f "$body"
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh mr-state exits 78" {
  run "$CODE" mr-state https://example/mr
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh mr-comments exits 78" {
  run "$CODE" mr-comments https://example/mr
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh merge-mr exits 78" {
  run "$CODE" merge-mr https://example/mr --method squash
  assert_not_implemented "$status" "$output"
}

@test "code/custom.sh issue-mrs exits 78 (#704)" {
  run "$CODE" issue-mrs acme/testproj 5 6
  assert_not_implemented "$status" "$output"
}

@test "issue/custom.sh unknown verb exits 2" {
  run "$ISSUE" wat
  [ "$status" -eq 2 ]
}

@test "code/custom.sh unknown verb exits 2" {
  run "$CODE" wat
  [ "$status" -eq 2 ]
}
