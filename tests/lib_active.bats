#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Two projects so single-project shortcut doesn't kick in unexpectedly.
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

@test "active_set/get_project round-trip writes mode 600" {
  active_set_project volk
  [ "$(active_get_project)" = "volk" ]
  local mode
  mode="$(stat -c '%a' "$(active_pointer_path)")"
  [ "$mode" = "600" ]
}

@test "active_resolve_project: explicit arg wins" {
  active_set_project volk
  export DEVAGENT_ACTIVE_PROJECT=gnuradio
  [ "$(active_resolve_project gnuradio)" = "gnuradio" ]
  [ "$(active_resolve_project volk)" = "volk" ]
}

@test "active_resolve_project: env var wins over global pointer" {
  active_set_project volk
  DEVAGENT_ACTIVE_PROJECT=gnuradio run active_resolve_project
  [ "$output" = "gnuradio" ]
}

@test "active_resolve_project: global pointer wins when no arg/env" {
  active_set_project gnuradio
  run active_resolve_project
  [ "$output" = "gnuradio" ]
}

@test "active_resolve_project: dies when no pointer and 2+ projects" {
  run active_resolve_project
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 projects"* ]]
}

@test "active_resolve_issue: arg wins" {
  state_init volk
  state_set volk active_issue Issue-5
  [ "$(active_resolve_issue volk Issue-99)" = "Issue-99" ]
}

@test "active_resolve_issue: per-project state wins when no arg/env" {
  state_init volk
  state_set volk active_issue Issue-42
  [ "$(active_resolve_issue volk)" = "Issue-42" ]
}

@test "active_resolve_issue: env var wins over per-project state" {
  state_init volk
  state_set volk active_issue Issue-42
  DEVAGENT_ACTIVE_ISSUE=Issue-99 run active_resolve_issue volk
  [ "$output" = "Issue-99" ]
}

@test "active_resolve_issue: scans devdoc when state has no active_issue" {
  # Two issue dirs, the older one complete, the newer one incomplete.
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1" \
           "$BATS_TEST_TMPDIR/devdoc/volk/Issue-2"
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1/checklist.md" <<'EOF'
- [x] 0. pull
- [x] 1. draft
EOF
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-2/checklist.md" <<'EOF'
- [x] 0. pull
- [ ] 1. draft
EOF
  # Make Issue-2 newer.
  touch -d "1 minute ago" "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1/checklist.md"
  state_init volk
  run active_resolve_issue volk
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-2" ]
}

@test "active_resolve_issue: returns most recently touched even with in-progress mark" {
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3"
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3/checklist.md" <<'EOF'
- [x] 0. pull
- [~] 1. draft
EOF
  state_init volk
  run active_resolve_issue volk
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-3" ]
}
