#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  ISSUE_DIR="$DA_HOME/Issue-1"
  mkdir -p "$ISSUE_DIR"
}

teardown() { teardown_tmp_devagent_home; }

@test "checklist_init writes a checklist from the standard template" {
  checklist_init "$ISSUE_DIR" standard
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '0. pull' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '20. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '## Log' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist_init substitutes placeholders" {
  ISSUE_ID=Issue-42 checklist_init "$ISSUE_DIR" standard
  run head -1 "$ISSUE_DIR/checklist.md"
  [[ "$output" == *"Issue-42"* ]]
}

@test "checklist_init refuses unknown template" {
  run checklist_init "$ISSUE_DIR" no-such-template
  [ "$status" -ne 0 ]
}

@test "checklist_current_step is 0 on a fresh standard" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "checklist_step_name maps numbers to names" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_step_name "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "pull" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 7
  [ "$output" = "implement" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 20
  [ "$output" = "cleanup" ]
}

@test "checklist_mark flips a glyph" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_mark refuses an unknown glyph" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_mark "$ISSUE_DIR/checklist.md" 0 Q
  [ "$status" -ne 0 ]
}

@test "checklist_advance marks current done and returns new current" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_advance "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_current_step echoes 'done' when all done" {
  checklist_init "$ISSUE_DIR" docs-only
  # docs-only has 10 steps; mark them all done
  for s in 0 1 6 9 10 12 13 15 16 20; do
    checklist_mark "$ISSUE_DIR/checklist.md" "$s" x
  done
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "done" ]
}

@test "checklist_current_step skips x, returns first non-x" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  checklist_mark "$ISSUE_DIR/checklist.md" 1 x
  checklist_mark "$ISSUE_DIR/checklist.md" 2 '~'
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "2" ]
}
