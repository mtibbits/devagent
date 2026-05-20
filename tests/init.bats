#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  rm -rf "$DA_HOME/secrets"  # ensure bootstrap is exercised
}
teardown() { teardown_tmp_devagent_home; }

@test "init bootstraps config, state file, and secrets dir" {
  # supply non-interactive answers via env
  DA_INIT_SOURCE_DIR="/tmp/srcvolk" \
  DA_INIT_DEVDOC_DIR="/tmp/devvolk" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" volk
  [ "$status" -eq 0 ]
  [ -f "$DA_HOME/config.toml" ]
  [ -f "$DA_HOME/state/volk.toml" ]
  [ -d "$DA_HOME/secrets" ]
  assert_file_mode "$DA_HOME/secrets" 700
  assert_file_mode "$DA_HOME/state/volk.toml" 600
  run grep -q '^\[project.volk\]' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  run grep -q 'backend = "github"' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
}

@test "init refuses to overwrite an existing project block" {
  DA_INIT_SOURCE_DIR="/tmp/srcvolk" \
  DA_INIT_DEVDOC_DIR="/tmp/devvolk" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  "$PLUGIN_ROOT/scripts/init.sh" volk
  run "$PLUGIN_ROOT/scripts/init.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "init refuses an empty project name" {
  run "$PLUGIN_ROOT/scripts/init.sh" ""
  [ "$status" -ne 0 ]
}

@test "init refuses a project name containing dots" {
  # Dots would produce nested TOML tables that break config discovery.
  run "$PLUGIN_ROOT/scripts/init.sh" foo.bar
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad project name"* ]]
}
