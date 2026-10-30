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

@test "#782 checklist-stuck --step marks the named row, not the current one" {
  for s in 2 4 5 6 7; do "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null; done
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --step 19 mergetoall "$ISSUE_DIR" "CI FAILED: x"
  [ "$status" -eq 0 ]
  grep -qE '^- \[!\] 19\. mergetoall' "$ISSUE_DIR/checklist.md"
  grep -qE '^- \[ \]  8\. branch' "$ISSUE_DIR/checklist.md"           # the current step is untouched
  grep -q '^Step:        19 mergetoall' "$ISSUE_DIR/STUCK"
  grep -q '^Reason:      CI FAILED: x' "$ISSUE_DIR/STUCK"
}

@test "#782 checklist-stuck --step refuses a row the checklist lacks" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --step 99 mergetoall "$ISSUE_DIR" "why"
  [ "$status" -ne 0 ]
  [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#782 checklist-stuck --step refuses a row whose name differs (#558 guard)" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --step 18 mergetoall "$ISSUE_DIR" "why"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to mark step 18 as 'mergetoall'"* ]]
  grep -qE '^- \[ \] 18\. ship' "$ISSUE_DIR/checklist.md"
  [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#782 checklist-stuck --step without a name is a usage error" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --step 19
  [ "$status" -eq 2 ]
  [[ "$output" == *"--step needs a step number and name"* ]]
}

@test "#885 checklist-stuck --name marks the named row, not the current one" {
  for s in 2 4 5 6 7 8 9 10 11 12 13; do "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" "$s" x >/dev/null; done
  "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 19 ' ' >/dev/null
  grep -qE '^- \[ \] 14\. draftmr' "$ISSUE_DIR/checklist.md"           # 14 is current
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --name mergetoall "$ISSUE_DIR" "CI FAILED: x"
  [ "$status" -eq 0 ]
  grep -qE '^- \[!\] 19\. mergetoall' "$ISSUE_DIR/checklist.md"
  grep -qE '^- \[ \] 14\. draftmr' "$ISSUE_DIR/checklist.md"           # the current step is untouched
  grep -q '^Step:        19 mergetoall' "$ISSUE_DIR/STUCK"
  grep -q '^Reason:      CI FAILED: x' "$ISSUE_DIR/STUCK"
}

@test "#885 checklist-stuck --name dies on an absent row, checklist byte-identical" {
  cp "$ISSUE_DIR/checklist.md" "$BATS_TEST_TMPDIR/before.md"
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --name mergemr "$ISSUE_DIR" "why"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no step named 'mergemr' in $ISSUE_DIR/checklist.md"* ]]
  cmp -s "$BATS_TEST_TMPDIR/before.md" "$ISSUE_DIR/checklist.md"
  [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 checklist-stuck --name without a name is a usage error" {
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --name
  [ "$status" -eq 2 ]
  [[ "$output" == *"--name needs a step name"* ]]
}
