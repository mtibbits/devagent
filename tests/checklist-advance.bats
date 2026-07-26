#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "advance marks current done and prints new current" {
  run "$PLUGIN_ROOT/scripts/checklist-advance.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now at step 2"* ]]
}

@test "advance is a no-op when all steps are done" {
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null
  done
  run "$PLUGIN_ROOT/scripts/checklist-advance.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all steps complete"* ]]
}
