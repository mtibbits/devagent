#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-lessons-learned"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-lessons"
}

@test "devagent-lessons-learned passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-lessons-learned references lessonsLearned_template" {
  grep -q 'lessonsLearned_template' "$SKILL/SKILL.md"
}

@test "devagent-lessons-learned tags actionable entries (for reap)" {
  grep -qi 'actionable' "$SKILL/SKILL.md"
}

@test "devagent-lessons fixture exists" {
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/actualWork.md" ]
}
