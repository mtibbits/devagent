#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "log appends a line" {
  run "$PLUGIN_ROOT/scripts/checklist-log.sh" "$ISSUE_DIR" pull "fetched #42"
  [ "$status" -eq 0 ]
  run grep 'pull: fetched #42' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}
