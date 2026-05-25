#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-draft-mr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-draftmr"
}

@test "core-draft-mr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-draft-mr references mr_template.md" {
  grep -q 'mr_template.md' "$SKILL/SKILL.md"
}

@test "core-draft-mr writes mr.md" {
  grep -qE '\bmr\.md\b' "$SKILL/SKILL.md"
}

@test "devagent-draftmr fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}
