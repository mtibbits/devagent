#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676" "$DEVDOC/Issue-203"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
## Log
EOF
  cat > "$DEVDOC/Issue-203/checklist.md" <<'EOF'
- [~]  3. improve
## Log
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "park marks active issue [P] and clears active_issue" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  # active_issue should no longer be Issue-676 (key removed or empty)
  ! grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  # Issue-676 must appear under [parked] table as `Issue-676 = true`
  grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
  # Either the [P] mark on step 1, or a "park: ..." log entry
  grep -E '^- \[P\] +1\. draft' "$DEVDOC/Issue-676/checklist.md" \
    || grep -q 'park: ' "$DEVDOC/Issue-676/checklist.md"
}

@test "park with explicit issue parks that one even if not active" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^Issue-203 *= *true' "$DA_HOME/state/volk.toml"
  # Active issue not changed
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
}

@test "resume reactivates a parked issue" {
  "$PLUGIN_ROOT/scripts/park.sh" volk
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  ! grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
}

@test "resume errors when issue isn't parked" {
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-999
  [ "$status" -ne 0 ]
  [[ "$output" == *"not parked"* || "$output" == *"unknown"* ]]
}

@test "switch parks current and resumes target" {
  # Park 203 so it's resumable
  "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-203"' "$DA_HOME/state/volk.toml"
  grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
}

@test "park errors when no active issue and no arg" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -ne 0 ]
}
