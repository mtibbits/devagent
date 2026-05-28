#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  rm -rf "$DA_HOME/secrets"  # ensure bootstrap is exercised
  # Default gh stub: report 'main' as the upstream default branch so init
  # tests stay hermetic (no network). Individual tests override as needed.
  STUB_BIN="$DA_HOME/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo main
EOF
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
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

@test "init detects upstream default branch (master) and writes branch_prefix_map" {
  # Override the default stub to report master.
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo master
EOF
  chmod +x "$STUB_BIN/gh"
  DA_INIT_SOURCE_DIR="/tmp/srcd" \
  DA_INIT_DEVDOC_DIR="/tmp/devd" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="mtibbits/devagent" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="mtibbits/devagent" \
  DA_INIT_CODE_FORK="mtibbits/devagent" \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" dev
  [ "$status" -eq 0 ]
  run grep -q 'default_baseline = "origin/master"' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  run grep -q 'branch_prefix_map' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
}

@test "init falls back to origin/main when gh api fails" {
  # Override the stub to fail (simulates no network / no auth).
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/gh"
  DA_INIT_SOURCE_DIR="/tmp/srcd" \
  DA_INIT_DEVDOC_DIR="/tmp/devd" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" volk
  [ "$status" -eq 0 ]
  run grep -q 'default_baseline = "origin/main"' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
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
