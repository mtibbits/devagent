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

@test "core-redmr defines the dispatch contract (#151)" {
  grep -q '## Dispatch contract' "$SKILL/SKILL.md"
  grep -q 'step-model.sh' "$SKILL/SKILL.md"
  grep -q 'paths, not' "$SKILL/SKILL.md"
  grep -q 'inherit' "$SKILL/SKILL.md"
  grep -q 'context: subagent' "$SKILL/SKILL.md"
  grep -q 'context: inline' "$SKILL/SKILL.md"
}
