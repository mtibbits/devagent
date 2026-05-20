#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  rm -rf "$DA_HOME/secrets"   # ensure clean
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "secrets_bootstrap creates dir mode 700" {
  secrets_bootstrap
  [ -d "$DA_HOME/secrets" ]
  assert_file_mode "$DA_HOME/secrets" 700
}

@test "secrets_bootstrap is idempotent" {
  secrets_bootstrap
  secrets_bootstrap
  assert_file_mode "$DA_HOME/secrets" 700
}

@test "secrets_audit warns when dir mode drifts" {
  secrets_bootstrap
  chmod 755 "$DA_HOME/secrets"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING"* ]]
}

@test "secrets_audit warns when a file mode drifts" {
  secrets_bootstrap
  echo dummy >"$DA_HOME/secrets/volk.github.pat"
  chmod 644 "$DA_HOME/secrets/volk.github.pat"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"volk.github.pat"* ]]
}
