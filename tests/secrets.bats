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
  # #289: drift is only representable where chmod takes effect; on a
  # no-op-chmod filesystem the audit correctly skips, so skip the test there.
  _c="$DA_HOME/.cg"; :>"$_c"; chmod 600 "$_c"
  [ "$(stat -c '%a' "$_c" 2>/dev/null)" = 600 ] || skip "chmod is a no-op here (Windows/noacl)"
  secrets_bootstrap
  chmod 755 "$DA_HOME/secrets"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARNING"* ]]
}

@test "secrets_audit warns when a file mode drifts" {
  _c="$DA_HOME/.cg"; :>"$_c"; chmod 600 "$_c"
  [ "$(stat -c '%a' "$_c" 2>/dev/null)" = 600 ] || skip "chmod is a no-op here (Windows/noacl)"
  secrets_bootstrap
  echo dummy >"$DA_HOME/secrets/volk.github.pat"
  chmod 644 "$DA_HOME/secrets/volk.github.pat"
  run secrets_audit
  [ "$status" -ne 0 ]
  [[ "$output" == *"volk.github.pat"* ]]
}
