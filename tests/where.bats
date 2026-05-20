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
  # Minimal checklist: step 2 done, step 3 in-progress
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
# Issue-676 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
- [~]  3. improve
- [ ]  4. prune
- [ ]  5. tighten

## Log
- 2026-05-19 14:32  improve: started analyzing edge cases
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "where reports active issue, last step, next step" {
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project: volk"* ]]
  [[ "$output" == *"Active issue: Issue-676"* ]]
  [[ "$output" == *"Current step: 3 (improve) [~]"* ]]
  [[ "$output" == *"Next step: 4 (prune)"* ]]
  [[ "$output" == *"Run /devagent:next to execute"* ]]
}

@test "where prints idle banner when no active issue" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "where surfaces STUCK file when present" {
  cat > "$DEVDOC/Issue-676/STUCK" <<'EOF'
Step: 3 improve
Reason: needs upstream API clarification
EOF
  # Mark step 3 as stuck
  sed -i 's/^- \[~\]  3\. improve/- [!]  3. improve/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"needs upstream API clarification"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "where reports parked issues" {
  cat >> "$DA_HOME/state/volk.toml" <<'EOF'

[parked]
"Issue-203"     = true
"Issue-Fork-12" = true
EOF
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parked:"* ]]
  [[ "$output" == *"Issue-203"* ]]
  [[ "$output" == *"Issue-Fork-12"* ]]
}

@test "where errors when project unknown" {
  run "$PLUGIN_ROOT/scripts/where.sh" nosuch
  [ "$status" -ne 0 ]
}
