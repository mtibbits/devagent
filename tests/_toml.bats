#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-onproject.toml
  TOML="$PLUGIN_ROOT/scripts/lib/_toml.py"
}

teardown() { teardown_tmp_devagent_home; }

@test "get reads a top-level scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "get reads a nested scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.devdoc_dir
  [ "$status" -eq 0 ]
  [ "$output" = "~/src/devDoc/volk" ]
}

@test "get returns nonzero on missing key" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.nope
  [ "$status" -ne 0 ]
}

@test "list-tables enumerates project subtable names" {
  run python3 "$TOML" list-tables "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project.volk"* ]]
  [[ "$output" == *"project.volk.issue_source"* ]]
}

@test "set then get round-trips a string" {
  python3 "$TOML" set "$DA_HOME/config.toml" project.volk.new_key '"hello world"'
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.new_key
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "set-bool writes a boolean" {
  python3 "$TOML" set-bool "$DA_HOME/config.toml" project.volk.fork_first false
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.fork_first
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "unset removes a key" {
  python3 "$TOML" unset "$DA_HOME/config.toml" defaults.checklist_template
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -ne 0 ]
}

@test "validate exits 0 on good file, nonzero on malformed" {
  run python3 "$TOML" validate "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  cp "$(fixtures_dir)/config-malformed.toml" "$DA_HOME/bad.toml"
  run python3 "$TOML" validate "$DA_HOME/bad.toml"
  [ "$status" -ne 0 ]
}

@test "concurrent writes do not lose updates" {
  # Launch 20 concurrent writers each setting a distinct key.
  # Without flock, lost-update races would drop some keys.
  local i pids=()
  for i in $(seq 1 20); do
    python3 "$TOML" set "$DA_HOME/config.toml" \
      "project.volk.race_$i" "\"v$i\"" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  # All 20 keys must be readable.
  local missing=0
  for i in $(seq 1 20); do
    run python3 "$TOML" get "$DA_HOME/config.toml" "project.volk.race_$i"
    [ "$status" -eq 0 ] || { missing=$((missing+1)); continue; }
    [ "$output" = "v$i" ] || missing=$((missing+1))
  done
  [ "$missing" -eq 0 ]
}

@test "lock file is released on exception" {
  # Force a malformed write (a bad value type) and verify the lock
  # does not stick around blocking subsequent writers.
  ! python3 "$TOML" set-bool "$DA_HOME/config.toml" \
      project.volk.fork_first not-a-bool
  # Now a normal write must still succeed.
  run python3 "$TOML" set "$DA_HOME/config.toml" \
      project.volk.after_error '"ok"'
  [ "$status" -eq 0 ]
}
