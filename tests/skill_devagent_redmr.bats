#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-redmr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-redmr"
}

@test "devagent-redmr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-redmr references redteam_mr template" {
  grep -q 'redteam_mr' "$SKILL/SKILL.md"
}

@test "devagent-redmr classifies findings by severity" {
  grep -qi 'blocking' "$SKILL/SKILL.md"
  grep -qi 'severity' "$SKILL/SKILL.md"
}

@test "devagent-redmr fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}
