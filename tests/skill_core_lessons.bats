#!/usr/bin/env bats

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

@test "devagent-lessons fixture exists" {
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/actualWork.md" ]
}
