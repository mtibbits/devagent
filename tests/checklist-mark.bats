#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "mark sets a glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 '~'
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  7\. implement' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "mark refuses an invalid glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 Q
  [ "$status" -ne 0 ]
}

@test "mark preserves the checklist file mode (#329)" {
  # A same-dir temp still comes from mktemp at 0600; without the mode-preserve the
  # mv resets the target. Born-red at 0644 (real checklists are 0600 and can't
  # distinguish the fix).
  chmod 644 "$ISSUE_DIR/checklist.md"
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 x
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$ISSUE_DIR/checklist.md")" = "644" ]
}
