#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-improve"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-improve"
}

@test "core-improve passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-improve covers bugs, side effects, ambiguities" {
  grep -qi 'bug' "$SKILL/SKILL.md"
  grep -qi 'side effect' "$SKILL/SKILL.md"
  grep -qi 'ambiguit' "$SKILL/SKILL.md"
}

@test "core-improve fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
