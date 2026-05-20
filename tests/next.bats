#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [ ]  2. scope
- [ ]  3. improve
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "next on step owned by later plan prints deferral and exits 0" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step 2 (scope)"* ]]
  [[ "$output" == *"deferred"* ]] || [[ "$output" == *"not yet wired"* ]]
}

@test "next refuses to advance when current step is [!]" {
  sed -i 's/^- \[ \]  2\. scope/- [!]  2. scope/' "$DEVDOC/Issue-676/checklist.md"
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "next refuses without active issue" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "--through accepts a step name" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"chain target: tighten"* ]]
}

@test "--auto implies through cleanup" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"chain target: cleanup"* ]]
}

@test "unknown --through step is rejected" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step"* ]]
}

@test "next when all steps done reports completion" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"All steps complete"* ]]
}
