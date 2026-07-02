#!/usr/bin/env bats
# #282: arg/env-resolved invocations must leave the global pointer untouched.
# Two simulated sessions (env-pinned vs arg-pinned) interleave; neither
# observes the other's project and neither rewrites _active.toml.
load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # 2-project config (inline heredoc — the lib_active.bats pattern; the
  # helper itself writes no config).
  cat > "$DA_HOME/config.toml" <<EOC
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/volk"

[project.gnuradio]
source_dir = "$BATS_TEST_TMPDIR/gnuradio"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/gnuradio"
EOC
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk" "$BATS_TEST_TMPDIR/devdoc/gnuradio"
  # Seed the pointer: known value, known mtime, and NO last_active_at line —
  # a real active_set_project write adds last_active_at (the non-vacuous
  # wrote-or-not signal), and the mtime seed catches a same-value rewrite.
  echo 'active_project = "volk"' > "$DA_HOME/state/_active.toml"
  touch -d '2026-01-01 00:00:00' "$DA_HOME/state/_active.toml"
}
teardown() { teardown_tmp_devagent_home; }

_pointer_fingerprint() {
  stat -c '%Y' "$DA_HOME/state/_active.toml"
  cat "$DA_HOME/state/_active.toml"
}

@test "arg-resolved next.sh leaves the pointer byte-identical (#282)" {
  before="$(_pointer_fingerprint)"
  run env -u DEVAGENT_ACTIVE_PROJECT "$PLUGIN_ROOT/scripts/next.sh" gnuradio
  after="$(_pointer_fingerprint)"
  [ "$before" = "$after" ]
}

@test "env-resolved next.sh leaves the pointer byte-identical (#282)" {
  before="$(_pointer_fingerprint)"
  DEVAGENT_ACTIVE_PROJECT=gnuradio run "$PLUGIN_ROOT/scripts/next.sh"
  after="$(_pointer_fingerprint)"
  [ "$before" = "$after" ]
}

@test "pointer-resolved next.sh still WRITES the pointer (existing behavior) (#282)" {
  run env -u DEVAGENT_ACTIVE_PROJECT "$PLUGIN_ROOT/scripts/next.sh"
  grep -q 'active_project = "volk"' "$DA_HOME/state/_active.toml"
  grep -q 'last_active_at' "$DA_HOME/state/_active.toml"
}

@test "interleaved sessions do not observe each other's project (#282)" {
  run env -u DEVAGENT_ACTIVE_PROJECT "$PLUGIN_ROOT/scripts/next.sh" gnuradio
  DEVAGENT_ACTIVE_PROJECT=gnuradio run "$PLUGIN_ROOT/scripts/next.sh"
  # Pointer still names volk with the seeded fingerprint (no write happened).
  grep -q 'active_project = "volk"' "$DA_HOME/state/_active.toml"
  run grep -q 'last_active_at' "$DA_HOME/state/_active.toml"
  [ "$status" -ne 0 ]
}
