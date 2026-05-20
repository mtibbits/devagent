#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "state_init creates a mode-600 file" {
  state_init volk
  [ -f "$DA_HOME/state/volk.toml" ]
  assert_file_mode "$DA_HOME/state/volk.toml" 600
}

@test "state_exists reflects state_init" {
  run state_exists volk
  [ "$status" -ne 0 ]
  state_init volk
  run state_exists volk
  [ "$status" -eq 0 ]
}

@test "state_set then state_get round-trips" {
  state_init volk
  state_set volk active_issue Issue-676
  run state_get volk active_issue
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-676" ]
}

@test "state_unset removes a key" {
  state_init volk
  state_set volk active_issue Issue-676
  state_unset volk active_issue
  run state_get volk active_issue
  [ -z "$output" ]
}

@test "parked list add/remove/list is idempotent" {
  state_init volk
  state_add_parked volk Issue-12
  state_add_parked volk Issue-12   # idempotent
  state_add_parked volk Issue-34
  run state_list_parked volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
  state_remove_parked volk Issue-12
  state_remove_parked volk Issue-12 # idempotent
  run state_list_parked volk
  [[ "$output" != *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
}

@test "state_active_project returns the most recently updated" {
  state_init volk
  state_init toy
  state_set toy  active_issue Issue-1
  sleep 1
  state_set volk active_issue Issue-2
  run state_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}

@test "state_active_project ignores projects with null active_issue" {
  state_init toy
  run state_active_project
  [ "$status" -ne 0 ]
}

@test "state_set updates updated_at field automatically" {
  state_init volk
  state_set volk active_issue Issue-1
  run state_get volk updated_at
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}
