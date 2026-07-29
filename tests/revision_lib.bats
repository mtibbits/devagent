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

@test "revision_block_text substitutes {{N}} and lists the full workflow (no pull) as pending (#76)" {
  run revision_block_text 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Revision 2"* ]]
  [[ "$output" == *"[ ]  2. draft"* ]]
  [[ "$output" == *"[ ] 16. redmr"* ]]
  # #76: the revision block must carry preship + the full closeout, else a
  # revised MR never re-merges/re-cleanups and bypasses the #149/#242 gates.
  [[ "$output" == *"[ ] 17. preship"* ]]
  [[ "$output" == *"[ ] 18. ship"* ]]
  # mergetoall ships pre-skipped; only an all_prs_branch project re-opens it.
  [[ "$output" == *"[-] 19. mergetoall"* ]]
  [[ "$output" == *"[ ] 20. updatewbs"* ]]
  [[ "$output" == *"[ ] 21. impact"* ]]
  [[ "$output" == *"[ ] 22. lessonslearned"* ]]
  [[ "$output" == *"[ ] 23. cleanup"* ]]
  # A revision never re-pulls.
  [[ "$output" != *"0. pull"* ]]
}

@test "revision_block.md matches checklist-standard's steps minus '0. pull' (#76 parity)" {
  # Static invariant: the two templates must never drift. Extract the
  # "- [ ] NN. name" step lines from each; the revision block is the standard
  # checklist with the pull step removed, same order.
  local repo; repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  local std_steps rev_steps expected
  std_steps="$(grep -oE '\[ \] +[0-9]+\. [a-z]+' "$repo/templates/checklist-standard.md")"
  rev_steps="$(grep -oE '\[ \] +[0-9]+\. [a-z]+' "$repo/templates/revision_block.md")"
  expected="$(printf '%s\n' "$std_steps" | grep -v ' 0\. pull')"
  # Non-vacuous guard: a broken regex would make both empty and pass "" = "".
  [ "$(printf '%s\n' "$rev_steps" | grep -c .)" -ge 20 ]
  [ "$rev_steps" = "$expected" ]
}

@test "revision_block_text keeps mergetoall pre-skipped for a project without all_prs_branch" {
  run revision_block_text 2 volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"[-] 19. mergetoall"* ]]
}

@test "revision_block_text flips mergetoall to pending when the project sets all_prs_branch" {
  cat >"$FIX_CONFIG_FILE" <<EOF
[project.volk]
source_dir     = "$BATS_TEST_TMPDIR/src/volk"
devdoc_dir     = "$BATS_TEST_TMPDIR/devdoc/volk"
all_prs_branch = "dev/all-prs"
EOF
  run revision_block_text 2 volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ ] 19. mergetoall"* ]]
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
