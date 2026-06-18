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

@test "init substitutes answers literally (A20: & in a path is not a sed metachar)" {
  # An '&' in the replacement was treated by sed as "the matched text", so the
  # placeholder leaked back into the rendered value. Substitution is now literal.
  DA_INIT_SOURCE_DIR='/tmp/a&b/src' \
  DA_INIT_DEVDOC_DIR="/tmp/devd" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK="mtibbits/volk" \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" amp
  [ "$status" -eq 0 ]
  run grep -F '"/tmp/a&b/src"' "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
}

@test "init validates the rendered config and refuses a value that breaks TOML (A20)" {
  # A literal double-quote in an answer makes the rendered string invalid TOML.
  # _toml.py validate must catch it before anything is installed.
  DA_INIT_SOURCE_DIR="/tmp/src" \
  DA_INIT_DEVDOC_DIR="/tmp/devd" \
  DA_INIT_ISSUE_BACKEND="github" \
  DA_INIT_ISSUE_REPO="gnuradio/volk" \
  DA_INIT_CODE_BACKEND="github" \
  DA_INIT_CODE_UPSTREAM="gnuradio/volk" \
  DA_INIT_CODE_FORK='mtibbits/"bad' \
  DA_YES=1 \
  run "$PLUGIN_ROOT/scripts/init.sh" badtoml
  [ "$status" -ne 0 ]
  # nothing installed: no [project.badtoml] block exists
  run grep -q '^\[project.badtoml\]' "$DA_HOME/config.toml"
  [ "$status" -ne 0 ]
}

@test "config.toml.skel carries the commented step_models advisory example (#150)" {
  local skel="$PLUGIN_ROOT/templates/config.toml.skel"
  run grep -q 'step_models' "$skel"
  [ "$status" -eq 0 ]
  # it must be commented (advisory, opt-in) — no live step_models table
  run grep -qE '^\[project\..*\.step_models\]' "$skel"
  [ "$status" -ne 0 ]
}

@test "config.toml.skel ships live merge_to_all_prs, not the dead gating keys (E11)" {
  local skel="$PLUGIN_ROOT/templates/config.toml.skel"
  # merge_to_all_prs is read by mergetoall.sh — it must be present (live).
  run grep -qE '^[[:space:]]*merge_to_all_prs[[:space:]]*=' "$skel"
  [ "$status" -eq 0 ]
  # transition_issue / cleanup_on_merge are read by nothing — must not ship as
  # live keys (they gave a false sense of gating).
  run grep -qE '^[[:space:]]*transition_issue[[:space:]]*=' "$skel"
  [ "$status" -ne 0 ]
  run grep -qE '^[[:space:]]*cleanup_on_merge[[:space:]]*=' "$skel"
  [ "$status" -ne 0 ]
}

@test "config.toml.skel documents the fork-workflow keys as commented examples (E14)" {
  local skel="$PLUGIN_ROOT/templates/config.toml.skel"
  local key
  for key in source_remote all_prs_branch all_prs_auto_push fork_only use_worktree include_coauthor issue_source_fork; do
    run grep -qE "^#.*${key}" "$skel"
    [ "$status" -eq 0 ] || { echo "E14: missing commented fork key '${key}'"; return 1; }
  done
}
