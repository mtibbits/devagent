#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-document-actual-work"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-document"
}

@test "core-document-actual-work passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-document-actual-work references actualWork_template" {
  grep -q 'actualWork_template' "$SKILL/SKILL.md"
}

@test "core-document-actual-work explicitly handles 'no deviation' case" {
  grep -qi 'no deviation' "$SKILL/SKILL.md"
}

@test "devagent-document fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/git-changes.diff" ]
}
