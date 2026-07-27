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
  run grep -E '^- \[ \]  2\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck with --in-progress flips ! to ~" {
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --in-progress "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  2\. draft' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unstuck refuses when no STUCK file exists" {
  rm -f "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}

@test "checklist-unstuck clears the highest step in the template (#558 r2 BLOCKING-2)" {
  # The pre-#558 loop bound (0..21) stranded steps 22/23 permanently and
  # reported a FALSE "no step is currently [!]" while STUCK sat on disk.
  "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR" >/dev/null
  sed -i -E '/23\. cleanup/ s/\[.\]/[!]/' "$ISSUE_DIR/checklist.md"
  echo "cleanup: planted failure" > "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$ISSUE_DIR/STUCK" ]
  grep -qE '^- \[ \] +23\. cleanup' "$ISSUE_DIR/checklist.md"
}

@test "checklist-unstuck ignores a [!] left in an inactive revision block" {
  # The bound-free scan derives candidates file-wide; scoping must still come
  # from checklist_step_state so a stale [!] in Revision 1 cannot shadow the
  # active block.
  "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR" >/dev/null
  # Freeze revision 1 with a stuck row, then append an active revision 2
  # whose only stuck row is 23. The scan must clear 23, not rev-1's row.
  sed -i -E '/2\. draft/ s/\[.\]/[!]/' "$ISSUE_DIR/checklist.md"
  {
    echo ""
    echo "## Revision 2"
    echo ""
    echo "- [x] 19. mergetoall"
    echo "- [!] 23. cleanup"
  } >> "$ISSUE_DIR/checklist.md"
  echo "cleanup: planted failure" > "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  # rev-2's 23 cleared (rev-1's pending 23 makes the count 2, not 1)...
  run grep -cE '^- \[ \] 23\. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$output" = "2" ]
  # ...and rev-1's stale [!] draft row untouched.
  grep -qE '^- \[!\]  2\. draft' "$ISSUE_DIR/checklist.md"
}

@test "checklist-unstuck clears an old-block [!] whose number is reused (#558 r3 BLOCKING-2)" {
  # The r2 rewrite carried the step NUMBER out of the scan; checklist_mark
  # then re-scoped it to the ACTIVE block, flipping rev-2's pending copy while
  # rev-1's [!] survived and STUCK was deleted — a fail-open wrong-row write.
  # Closeout numbers are REUSED in every revision block (#76), so this is the
  # normal revise-then-unstuck shape, not an exotic one.
  "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR" >/dev/null
  sed -i -E '/19\. mergetoall/ s/\[.\]/[!]/' "$ISSUE_DIR/checklist.md"
  {
    echo ""
    echo "## Revision 2"
    echo ""
    echo "- [ ] 19. mergetoall"
    echo "- [ ] 23. cleanup"
  } >> "$ISSUE_DIR/checklist.md"
  echo "mergetoall: planted failure" > "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --in-progress "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  # rev-1's [!] row is the one flipped...
  run grep -cE '^- \[~\] 19\. mergetoall' "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
  grep -qE '^- \[!\]' "$ISSUE_DIR/checklist.md" && _fail_stuck_row_survived=1
  [ -z "${_fail_stuck_row_survived:-}" ]
  # ...and rev-2's pending copy is untouched.
  run grep -cE '^- \[ \] 19\. mergetoall' "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
}

@test "checklist-unstuck clears a step-17 preship [!] (#149)" {
  # The pre-#149 loop bound stranded the preship row permanently. Clear the
  # fixture's first [!] so preship (17) is the only stuck step.
  "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR" >/dev/null
  sed -i -E '/17\. preship/ s/\[.\]/[!]/' "$ISSUE_DIR/checklist.md"
  echo "preship: planted failure" > "$ISSUE_DIR/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \] +17\. preship' "$ISSUE_DIR/checklist.md"
}
