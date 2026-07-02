#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; }
teardown() { teardown_tmp_devagent_home; }

@test "checklist-init.sh creates a checklist with default template" {
  ISSUE_DIR="$DA_HOME/Issue-1"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '20. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh accepts --template flag" {
  ISSUE_DIR="$DA_HOME/Issue-2"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template research "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -q 'Template: research' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh fails on bad template" {
  ISSUE_DIR="$DA_HOME/Issue-3"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template foo "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}

@test "standard template carries preship (21) between redmr and ship in file order (#149)" {
  ISSUE_DIR="$DA_HOME/Issue-149t"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  awk '/14\. redmr/{r=NR} /21\. preship/{p=NR} /15\. ship/{s=NR} END{exit !(r<p && p<s)}' "$ISSUE_DIR/checklist.md"
}
