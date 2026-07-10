#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Two projects so the single-project shortcut doesn't mask the pointer write.
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/volk"

[project.gnuradio]
source_dir = "$BATS_TEST_TMPDIR/gnuradio"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/gnuradio"
EOF
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk" "$BATS_TEST_TMPDIR/devdoc/gnuradio"
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/active.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "use writes the pointer and next resolves the new project with NO env pin (#349 AC)" {
  active_set_project volk
  run bash "$PLUGIN_ROOT/scripts/use.sh" gnuradio
  [ "$status" -eq 0 ]
  # the shared pointer moved...
  [ "$(active_get_project)" = "gnuradio" ]
  # ...and the resolution chain next.sh uses (no arg, no env) picks it up.
  unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE
  [ "$(active_resolve_project)" = "gnuradio" ]
}

@test "use prints the resolved state (project + active-issue line)" {
  run bash "$PLUGIN_ROOT/scripts/use.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active project → volk"* ]]
  [[ "$output" == *"Project: volk"* ]]
  [[ "$output" == *"Active issue:"* ]]
}

@test "use rejects an unknown project and leaves the pointer UNCHANGED" {
  active_set_project volk
  run bash "$PLUGIN_ROOT/scripts/use.sh" nosuchproject
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in config.toml"* ]]
  # pointer must not have been bricked/overwritten (validate-before-write).
  [ "$(active_get_project)" = "volk" ]
}

@test "use with no argument dies with a usage hint" {
  run bash "$PLUGIN_ROOT/scripts/use.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project required"* ]]
}
