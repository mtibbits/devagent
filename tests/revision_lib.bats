#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  # shellcheck source=/dev/null
  source "$DEVAGENT_ROOT/scripts/lib/revision.sh"
}

@test "revision_current returns 1 from fixture state" {
  run revision_current volk
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "revision_current defaults to 1 when state file has no revision key" {
  printf 'active_issue = "Issue-1"\n' >"$FIX_STATE_FILE"
  run revision_current volk
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "revision_dir composes <issue-dir>/revisions/r<N>" {
  run revision_dir "$FIX_ISSUE_DIR" 3
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_ISSUE_DIR/revisions/r3" ]
}

@test "revision_block_text substitutes {{N}} and lists steps 1-15 as pending" {
  run revision_block_text 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Revision 2"* ]]
  [[ "$output" == *"[ ]  1. draft"* ]]
  [[ "$output" == *"[ ] 15. ship"* ]]
  [[ "$output" != *"0. pull"* ]]
  [[ "$output" != *"16. mergetoall"* ]]
  [[ "$output" != *"20. cleanup"* ]]
}
