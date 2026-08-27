#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-prune"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-prune"
}

@test "core-prune passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-prune mentions potentialFutureEnhancements file" {
  grep -q 'imPlan-potentialFutureEnhancements.md' "$SKILL/SKILL.md"
}

@test "core-prune fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
