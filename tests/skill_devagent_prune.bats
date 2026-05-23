#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-prune"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-prune"
}

@test "devagent-prune passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-prune mentions potentialFutureEnhancements file" {
  grep -q 'imPlan-potentialFutureEnhancements.md' "$SKILL/SKILL.md"
}

@test "devagent-prune fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
