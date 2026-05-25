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
- [ ]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ] 20. cleanup
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "next on a skill-backed step prints the slash command to invoke" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  [[ "$output" == *"skill-backed"* ]]
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

@test "--through accepts a step name present in the checklist" {
  # First skill-backed step (scope) is still emitted; chain doesn't run
  # past it because we have no script for it. Just assert it doesn't error
  # and we did get the slash-command pointer.
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "--auto implies through cleanup" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "unknown --through step is rejected against this issue's checklist" {
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

@test "next with no project arg uses the only configured project" {
  run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "next with no project arg respects DEVAGENT_ACTIVE_PROJECT env var" {
  # Add a second project so single-project resolution would die.
  cat >> "$DA_HOME/config.toml" <<EOF

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
EOF
  DEVAGENT_ACTIVE_PROJECT=volk run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "next with no project arg dies when multiple projects configured" {
  cat >> "$DA_HOME/config.toml" <<EOF

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
EOF
  run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 projects configured"* ]]
}

@test "next --auto emits CHAIN: marker on skill-backed steps" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  [[ "$output" == *"CHAIN: /devagent:next --auto"* ]]
}

@test "next --through propagates into CHAIN: marker" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAIN: /devagent:next --through tighten"* ]]
}

@test "next --through stops once the target is marked done" {
  # Simulate: tighten was the chain target and the skill marked it [x].
  # The model re-invokes /devagent:next --through tighten. We must NOT
  # advance into the next step (branch).
  sed -i 's/^- \[ \]  5\. tighten/- [x]  5. tighten/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"target 'tighten' is complete"* ]]
  [[ "$output" != *"/devagent:branch"* ]]
  [[ "$output" != *"CHAIN:"* ]]
}

@test "next without chain flags omits CHAIN: marker" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  [[ "$output" != *"CHAIN:"* ]]
}

@test "next dispatches purely from THIS checklist, not a canonical step list" {
  # A planning-only issue's checklist with non-canonical numbering and
  # a custom skill-backed step that isn't in any global list. Authority
  # is the checklist; next.sh just reads it.
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [ ]  9. brainstorm
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:brainstorm"* ]]
}
