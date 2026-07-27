#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 0 x >/dev/null
}
teardown() { teardown_tmp_devagent_home; }

@test "stuck marks current step ! and writes STUCK file" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "needs help with X"
  [ "$status" -eq 0 ]
  [ -f "$ISSUE_DIR/STUCK" ]
  run grep -E '^- \[!\]  2\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep 'Reason:' "$ISSUE_DIR/STUCK"
  [[ "$output" == *"needs help with X"* ]]
}

@test "stuck refuses when checklist already done" {
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null
  done
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$ISSUE_DIR" "why"
  [ "$status" -ne 0 ]
}
