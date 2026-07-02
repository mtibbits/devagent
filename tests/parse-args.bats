#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Use the two-project fixture (volk + toy) shipped in Plan 1
  install_fixture_config config-twoproject.toml
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/parse-args.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "parses bare project name" {
  parse_devagent_args volk
  [ "$DA_PROJECT" = "volk" ]
  [ -z "$DA_ISSUE" ]
  [ -z "$DA_NOTE" ]
}

@test "parses project + issue + note" {
  parse_devagent_args volk Issue-676 ship despite lint warning
  [ "$DA_PROJECT" = "volk" ]
  [ "$DA_ISSUE" = "Issue-676" ]
  [ "$DA_NOTE" = "ship despite lint warning" ]
}

@test "parses Issue-Fork-N form" {
  parse_devagent_args volk Issue-Fork-42
  [ "$DA_ISSUE" = "Issue-Fork-42" ]
}

@test "-- separator stops positional consumption" {
  parse_devagent_args volk -- please ship despite the lint warning
  [ "$DA_PROJECT" = "volk" ]
  [ -z "$DA_ISSUE" ]
  [ "$DA_NOTE" = "please ship despite the lint warning" ]
}

@test "unknown first token becomes note when only one project configured" {
  # Trim fixture to one project
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "/tmp/volk"
EOF
  parse_devagent_args random words here
  [ "$DA_PROJECT" = "volk" ]
  [ "$DA_NOTE" = "random words here" ]
}

@test "no args with one configured project picks that project" {
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "/tmp/volk"
EOF
  parse_devagent_args
  [ "$DA_PROJECT" = "volk" ]
}

@test "no args with multiple projects and no active falls back to empty" {
  parse_devagent_args
  [ -z "$DA_PROJECT" ]
}

@test "no args with global active pointer (_active.toml) uses it (#282)" {
  echo 'active_project = "toy"' > "$DA_HOME/state/_active.toml"
  parse_devagent_args
  [ "$DA_PROJECT" = "toy" ]
}

@test "no args: DEVAGENT_ACTIVE_PROJECT wins over the pointer (#282)" {
  echo 'active_project = "toy"' > "$DA_HOME/state/_active.toml"
  DEVAGENT_ACTIVE_PROJECT=volk parse_devagent_args
  [ "$DA_PROJECT" = "volk" ]
}
