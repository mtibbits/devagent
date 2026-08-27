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
