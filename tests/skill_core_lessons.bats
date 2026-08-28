#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-lessons-learned"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-lessons"
}

@test "core-lessons-learned passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-lessons-learned references lessonsLearned_template" {
  grep -q 'lessonsLearned_template' "$SKILL/SKILL.md"
}

@test "core-lessons-learned tags actionable entries (for reap)" {
  grep -qi 'actionable' "$SKILL/SKILL.md"
}

@test "core-lessons-learned promotes patterns to the register, neutral + deduped (#286)" {
  # Promote step exists and targets the register.
  grep -qi 'potholes' "$SKILL/SKILL.md"
  # Dedupe-by-citation and project-neutral guards are both stated.
  grep -qi 'dedupe by citation' "$SKILL/SKILL.md"
  grep -qi 'project-neutral' "$SKILL/SKILL.md"
}

@test "devagent-lessons fixture exists" {
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/actualWork.md" ]
}

@test "core-lessons-learned STAGES promotions via the script, never editing the register in the tree (#586)" {
  grep -qF 'promote-potholes.sh' "$SKILL/SKILL.md"
  grep -qF -- '--add' "$SKILL/SKILL.md"
  # the old "append it to the resolved potholes register" instruction must be gone
  run grep -niE 'append .{0,40}(to the )?resolved `?potholes' "$SKILL/SKILL.md"
  [ "$status" -ne 0 ]
  # the durability rationale is stated where the operator reads it
  grep -qiF 'uncommitted' "$SKILL/SKILL.md"
}

@test "core-lessons-learned's promote command is a SINGLE line under the existing Bash grant (#584)" {
  # a multi-line command is refused by the permission matcher even when its first
  # line prefix-matches the grant (register: Issue-584)
  run awk '/promote-potholes\.sh/ && /\\$/' "$SKILL/SKILL.md"
  [ -z "$output" ]
}

@test "item 7 makes --layer mandatory and states the routing judgment for both layers (#611)" {
  grep -qF -- '--add --layer' "$SKILL/SKILL.md"
  grep -qF -- '`--layer project`' "$SKILL/SKILL.md"
  grep -qF -- '`--layer workflow`' "$SKILL/SKILL.md"
  grep -qF -- '(<project> Issue-N)' "$SKILL/SKILL.md"
  run grep -n 'every project but devagent' "$SKILL/SKILL.md"
  [ "$status" -eq 1 ]
}
