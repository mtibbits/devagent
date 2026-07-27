#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
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
- [~]  2. draft
- [ ]  4. scope
## Log
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "stuck marks current step [!] and writes STUCK file" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk "needs upstream API clarification"
  [ "$status" -eq 0 ]
  grep -E '^\- \[!\]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
  [ -f "$DEVDOC/Issue-676/STUCK" ]
  grep -q "needs upstream API clarification" "$DEVDOC/Issue-676/STUCK"
  grep -q "Step: *2 draft" "$DEVDOC/Issue-676/STUCK"
}

@test "stuck appends a log entry" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  grep -E 'draft: stuck — blocked' "$DEVDOC/Issue-676/checklist.md"
}

@test "stuck requires a reason" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"reason"* ]]
}

@test "unstuck removes STUCK file and flips [!] back to [~] by default" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  grep -E '^\- \[~\]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck --pending flips to [ ]" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk --pending
  [ "$status" -eq 0 ]
  grep -E '^\- \[ \]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck is a no-op (with warning) when no STUCK file" {
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"no STUCK"* ]]
}
