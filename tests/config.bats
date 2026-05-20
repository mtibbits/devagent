#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "config_load passes on a good file" {
  run config_load
  [ "$status" -eq 0 ]
}

@test "config_load dies on a missing file" {
  rm "$DA_HOME/config.toml"
  run config_load
  [ "$status" -ne 0 ]
}

@test "config_get reads a default" {
  run config_get defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "config_get_project_field reads a nested field" {
  run config_get_project_field volk issue_source.repo
  [ "$status" -eq 0 ]
  [ "$output" = "gnuradio/volk" ]
}

@test "config_list_projects lists both" {
  run config_list_projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"toy"*  ]]
}

@test "config_is_project true/false" {
  run config_is_project volk
  [ "$status" -eq 0 ]
  run config_is_project nope
  [ "$status" -ne 0 ]
}

@test "config_active_project dies on multi-project file" {
  run config_active_project
  [ "$status" -ne 0 ]
}

@test "config_active_project echoes the one project on single-project file" {
  install_fixture_config config-onproject.toml
  run config_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}
