#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/backend-common.sh"
}

@test "bc_have_cli returns 0 when command exists" {
  bc_have_cli bash
}

@test "bc_have_cli returns 1 when command missing" {
  run bc_have_cli definitely-not-a-real-command-xyz
  [ "$status" -eq 1 ]
}

@test "bc_die_not_implemented exits 78 with message" {
  run bash -c "source scripts/lib/backend-common.sh; bc_die_not_implemented custom create"
  [ "$status" -eq 78 ]
  [[ "$output" == *"not implemented"* ]]
  [[ "$output" == *"custom"* ]]
  [[ "$output" == *"create"* ]]
}

@test "bc_emit_fetch_header produces spec-shape markdown" {
  run bc_emit_fetch_header "foo/bar" "42" "Sample title" "open" "alice" "bug,perf" "https://example/42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# foo/bar#42 — Sample title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,perf"* ]]
  [[ "$output" == *"- URL: https://example/42"* ]]
}

@test "bc_emit_comment produces spec-shape comment block" {
  run bc_emit_comment "reviewer" "2026-05-12" "Looks good"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}
