#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  source "$PLUGIN_ROOT/scripts/lib/log.sh"
  ISSUE_DIR="$DA_HOME/Issue-1"
  mkdir -p "$ISSUE_DIR"
  checklist_init "$ISSUE_DIR" standard
}

teardown() { teardown_tmp_devagent_home; }

@test "log_append writes an ISO-stamped line under ## Log" {
  log_append "$ISSUE_DIR" pull "fetched gnuradio/volk#1, scaffold created"
  run grep -E '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} +pull: fetched' \
    "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "log_append preserves existing log lines and appends in order" {
  log_append "$ISSUE_DIR" pull   "fetched #1"
  log_append "$ISSUE_DIR" draft  "imPlan written"
  local n
  n="$(grep -c '^- 20' "$ISSUE_DIR/checklist.md")"
  [ "$n" = "2" ]
  run grep -n '^- 20' "$ISSUE_DIR/checklist.md"
  # second match must contain 'draft'
  [[ "${lines[1]}" == *"draft"* ]]
}

@test "log_append refuses missing checklist" {
  rm "$ISSUE_DIR/checklist.md"
  run log_append "$ISSUE_DIR" pull "x"
  [ "$status" -ne 0 ]
}

@test "log_tail returns last N log lines" {
  for i in 1 2 3 4 5; do
    log_append "$ISSUE_DIR" pull "msg $i"
  done
  run log_tail "$ISSUE_DIR" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"msg 4"* ]]
  [[ "$output" == *"msg 5"* ]]
  [[ "$output" != *"msg 3"* ]]
}

@test "log_append rejects multi-line message" {
  run log_append "$ISSUE_DIR" pull $'line1\nline2'
  [ "$status" -ne 0 ]
}
