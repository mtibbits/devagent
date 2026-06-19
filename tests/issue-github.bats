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

@test "fetch ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"# gnuradio/volk#676 — Demo issue title"* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" != *"new release of gh"* ]]   # notice must not leak into output
}

@test "state ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" state gnuradio/volk 676
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

@test "comment-list ignores gh stderr notices on success (#86)" {
  export GH_STUB_CASE="noisy"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" comment-list gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"First comment."* ]]
  [[ "$output" != *"new release of gh"* ]]
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

# ---- #87: github_labels config fallback + fail-safe skip for transitions ----
# These exercise cmd_transition's stage→label resolution. The gh-stub logs every
# `gh issue edit` to GH_STUB_ARGS_LOG, so "the label step ran / did not run" is
# directly observable, and GH_STUB_MISSING_LABEL simulates a label absent from
# the repo.

# Write a per-project github_labels config into the temp DA_HOME (#87).
_write_github_labels_config() {
  cat > "$DA_HOME/config.toml" <<TOML
[project.testproj.github_labels]
on_ship = "shipped"
TOML
}

@test "transition: unconfigured on_ship makes no gh issue edit call (#87)" {
  export DEVAGENT_PROJECT="testproj"
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  : > "$GH_STUB_ARGS_LOG"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship
  [ "$status" -eq 0 ]
  # fail-safe skip: the stub logged no `gh issue edit` invocation at all
  [ ! -s "$GH_STUB_ARGS_LOG" ]
}

@test "transition: configured github_labels.on_ship is applied (#87)" {
  export DEVAGENT_PROJECT="testproj"
  _write_github_labels_config
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  : > "$GH_STUB_ARGS_LOG"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship
  [ "$status" -eq 0 ]
  run grep -q -- '--add-label shipped' "$GH_STUB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "transition: configured-but-missing label skips cleanly, exit 0 (#87)" {
  export DEVAGENT_PROJECT="testproj"
  _write_github_labels_config
  # "shipped" (configured) and "on_ship" (the old bug's fallthrough) both absent
  export GH_STUB_MISSING_LABEL="shipped on_ship"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship
  [ "$status" -eq 0 ]
}

@test "transition: DEVAGENT_GITHUB_LABEL_ON_SHIP env overrides config (#87)" {
  export DEVAGENT_PROJECT="testproj"
  _write_github_labels_config
  export DEVAGENT_GITHUB_LABEL_ON_SHIP="env-ship"
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  : > "$GH_STUB_ARGS_LOG"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 on_ship
  [ "$status" -eq 0 ]
  run grep -q -- '--add-label env-ship' "$GH_STUB_ARGS_LOG"
  [ "$status" -eq 0 ]
}

@test "transition: built-in in_progress default still applies (#87 regression)" {
  export DEVAGENT_PROJECT="testproj"
  export GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/gh-args"
  : > "$GH_STUB_ARGS_LOG"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" transition gnuradio/volk 676 in_progress
  [ "$status" -eq 0 ]
  run grep -q -- '--add-label in progress' "$GH_STUB_ARGS_LOG"
  [ "$status" -eq 0 ]
}
