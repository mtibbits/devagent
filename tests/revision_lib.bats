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

@test "revision_current reads the top-level revision with a [parked] table present (#97)" {
  # The replaced reader is now section-aware (state_get): a [parked] table must not
  # perturb the top-level revision read (the reader-side analog of the writer repro).
  printf 'revision = 4\n\n[parked]\nIssue-999 = "2026-06-01T00:00:00Z"\n' >"$FIX_STATE_FILE"
  run revision_current volk
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
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

@test "revision_current honors DA_HOME, not \$HOME (#83 guard for the #97 fix)" {
  # Point DA_HOME at a fresh state dir with revision=7. revision_current must
  # read from there (via state_get -> state_path -> devagent_home), not a
  # hardcoded \$HOME/.claude/devagent/state. Guards against a regression to B14.
  local alt; alt="$(mktemp -d)"
  mkdir -p "$alt/state"
  printf 'active_issue = "Issue-1"\nrevision = 7\n' >"$alt/state/volk.toml"
  DA_HOME="$alt" run revision_current volk
  rm -rf "$alt"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}
