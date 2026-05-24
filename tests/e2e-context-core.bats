#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "full context-core happy path" {
  # pull → scaffold
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]

  # where → reports active
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-676"* ]]

  # status → one project
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [ "$status" -eq 0 ]

  # catchup → rehydration
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Catchup"* ]]

  # park → out of active
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]

  # where → idle banner
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [[ "$output" == *"No active issue"* ]]

  # resume → back active
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]

  # stuck/unstuck cycle
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk "checking something"
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]  # halts on [!]
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]

  # next → skill-backed step 1 (draft) emits its slash command pointer
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:draft"* ]]
}
