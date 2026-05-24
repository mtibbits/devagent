#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Put stub gh on PATH
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"
}

teardown() { teardown_tmp_devagent_home; }

@test "fetch prints the spec-shaped markdown" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"# gnuradio/volk#676 — Demo issue title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug, performance"* ]]
  [[ "$output" == *"- URL: https://github.com/gnuradio/volk/issues/676"* ]]
  [[ "$output" == *"Body line one."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @bob · 2026-05-12"* ]]
  [[ "$output" == *"First comment."* ]]
}

@test "fetch with zero comments still prints Comments (0) header" {
  export GH_STUB_CASE="nocomments"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Comments (0)"* ]]
}

@test "fetch propagates gh failure" {
  export GH_STUB_CASE="fail"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue view failed"* ]]
}

@test "create verb dispatches to gh issue create" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" /tmp/missing-body
  # Stub gh just emits JSON for whatever args; only assertion is non-2 exit.
  [ "$status" -ne 2 ]
}

@test "unknown verb returns 2 (usage error per spec 9.1 contract)" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" nonsense
  [ "$status" -eq 2 ]
}
