#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC1="$BATS_TEST_TMPDIR/devDoc/volk"
  DEVDOC2="$BATS_TEST_TMPDIR/devDoc/other"
  mkdir -p "$DEVDOC1/Issue-1" "$DEVDOC2/Issue-9"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC1"

[project.other]
devdoc_dir = "$DEVDOC2"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$DEVDOC1/Issue-1"

[parked]
"Issue-7" = true
EOF
  cat > "$DEVDOC1/Issue-1/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  2. draft
- [ ]  4. scope
EOF
  cat > "$DA_HOME/state/other.toml" <<EOF
active_issue = "Issue-9"
issue_dir = "$DEVDOC2/Issue-9"
EOF
  cat > "$DEVDOC2/Issue-9/checklist.md" <<'EOF'
- [!]  5. improve
EOF
  echo "Reason: stuck" > "$DEVDOC2/Issue-9/STUCK"
}

teardown() { teardown_tmp_devagent_home; }

@test "status volk shows that project only" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" != *"other"* ]]
}

@test "status --all shows both projects" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"other"* ]]
}

@test "status flags STUCK issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"Issue-9"* ]]
}

@test "status lists parked issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Parked: Issue-7"* ]]
}

@test "status shows current step name for active issue" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Issue-1"* ]]
  [[ "$output" == *"draft"* ]]
}

@test "status with no projects configured prints empty banner" {
  : > "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No projects configured"* ]]
}
