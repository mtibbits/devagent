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
  run python3 "$TOML" set-bool "$DA_HOME/config.toml" \
      project.volk.fork_first not-a-bool
  [ "$status" -ne 0 ]
  # Now a normal write must still succeed.
  run python3 "$TOML" set "$DA_HOME/config.toml" \
      project.volk.after_error '"ok"'
  [ "$status" -eq 0 ]
}

@test "mutation refuses a comment-bearing file, leaving it intact (#100)" {
  local f="$BATS_TEST_TMPDIR/commented.toml"
  printf '# hand-written rationale\nkey = "v"  # inline note\n' > "$f"
  run python3 "$TOML" set "$f" key '"new"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to mutate"* ]]
  grep -q '# hand-written rationale' "$f"   # comment preserved
  grep -q 'key = "v"' "$f"                  # value untouched
}

@test "mutation proceeds on a comment-free file (#100)" {
  local f="$BATS_TEST_TMPDIR/plain.toml"
  printf 'key = "v"\n' > "$f"
  run python3 "$TOML" set "$f" key '"new"'
  [ "$status" -eq 0 ]
  run python3 "$TOML" get "$f" key
  [ "$output" = "new" ]
}

@test "a # inside a quoted string is not treated as a comment (#100)" {
  local f="$BATS_TEST_TMPDIR/hashval.toml"
  printf 'url = "http://x/y#frag"\n' > "$f"
  run python3 "$TOML" set "$f" k '"v"'
  [ "$status" -eq 0 ]   # the # is in a string, not a comment → mutation allowed
}
