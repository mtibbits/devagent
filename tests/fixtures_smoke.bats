#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
}

@test "fixture_init creates expected files" {
  [ -f "$FIX_CONFIG_FILE" ]
  [ -f "$FIX_STATE_FILE" ]
  [ -f "$FIX_ISSUE_DIR/checklist.md" ]
  [ -d "$FIX_ISSUE_DIR/revisions" ]
}

@test "fixture state file has revision = 1" {
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}
