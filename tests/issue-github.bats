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

@test "create returns the bare issue number, not the URL (#27)" {
  # Real gh prints the new issue's URL; the backend contract is a bare number.
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
}

@test "create fails loudly when gh output has no parseable number (#27)" {
  export GH_STUB_CREATE_URL="not-a-url"
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]]   # pin to the numeric-guard branch, not any non-zero exit
}

@test "create returns the bare number via the inline-body path (empty body file) (#27)" {
  # Empty body_file → cmd_create's inline --body "" branch; still returns the number.
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" ""
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
}

@test "create fails when a non-empty body file does not exist (#89)" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" /tmp/does-not-exist-89
  [ "$status" -eq 2 ]
  [[ "$output" == *"body file not found"* ]]
}

@test "create forwards --label to gh (#89)" {
  echo body > "$BATS_TEST_TMPDIR/body.md"
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md" --label audit --label priority
  [ "$status" -eq 0 ]
  [ "$output" = "85" ]
  grep -q -- '--label audit' "$GH_STUB_ARGS_LOG"
  grep -q -- '--label priority' "$GH_STUB_ARGS_LOG"
}

@test "create rejects an unknown arg (#89)" {
  echo body > "$BATS_TEST_TMPDIR/body.md"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" "$BATS_TEST_TMPDIR/body.md" --bogus x
  [ "$status" -eq 2 ]
}

@test "unknown verb returns 2 (usage error per spec 9.1 contract)" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" nonsense
  [ "$status" -eq 2 ]
}
