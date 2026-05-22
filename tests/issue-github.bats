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

@test "unimplemented verb returns 64 with helpful message" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" /tmp/b
  [ "$status" -eq 64 ]
  [[ "$output" == *"not implemented"* ]]
}

@test "unknown verb returns 64" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" nonsense
  [ "$status" -eq 64 ]
}
