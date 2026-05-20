#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 0 x >/dev/null
  "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "blocked" >/dev/null
}
teardown() { teardown_tmp_devagent_home; }

@test "unstuck with --pending flips ! to ' ' and removes STUCK" {
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$ISSUE_DIR/STUCK" ]
  run grep -E '^- \[ \]  1\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck with --in-progress flips ! to ~" {
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --in-progress "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  1\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck refuses when no STUCK file exists" {
  rm -f "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}
