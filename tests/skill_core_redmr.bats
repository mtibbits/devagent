#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-redmr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-redmr"
}

@test "core-redmr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-redmr references redteam_mr template" {
  grep -q 'redteam_mr' "$SKILL/SKILL.md"
}

@test "core-redmr classifies findings by severity" {
  grep -qi 'blocking' "$SKILL/SKILL.md"
  grep -qi 'severity' "$SKILL/SKILL.md"
}

@test "core-redmr fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-redmr carries the spec-touch question covering adds/renames/removals (#435)" {
  grep -qi 'spec-touch' "$SKILL/SKILL.md"
  # all three lag classes named
  grep -qiE 'add' "$SKILL/SKILL.md"
  grep -qiE 'renam' "$SKILL/SKILL.md"
  grep -qiE 'remov' "$SKILL/SKILL.md"
  # the spec-relevant surfaces named
  grep -qiE 'config key' "$SKILL/SKILL.md"
  grep -qiE 'top-level director' "$SKILL/SKILL.md"
}
