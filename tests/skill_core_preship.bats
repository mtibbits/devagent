#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-preship"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-preship"
}

@test "core-preship passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-preship performs the three verifications" {
  grep -qi 'acceptance criteria' "$SKILL/SKILL.md"
  grep -qi 'findings applied' "$SKILL/SKILL.md"
  grep -qi 'push preview' "$SKILL/SKILL.md"
}

@test "core-preship fails to [!] via checklist-stuck with the correct signature (#149)" {
  # No step-number argument — the script marks the CURRENT step.
  grep -q 'checklist-stuck.sh" "$ISSUE_DIR" "preship:' "$SKILL/SKILL.md"
  grep -q '/devagent:unstuck' "$SKILL/SKILL.md"
}

@test "core-preship zero-diff auto-skip is fail-safe (#149)" {
  grep -q 'zero_diff_classify' "$SKILL/SKILL.md"
  grep -qi 'indeterminate' "$SKILL/SKILL.md"
}

@test "core-preship fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-preship carries the spec-touch verification covering adds/renames/removals (#435)" {
  grep -qi 'spec-touch' "$SKILL/SKILL.md"
  grep -qiE 'renam' "$SKILL/SKILL.md"
  grep -qiE 'remov' "$SKILL/SKILL.md"
  grep -qiE 'config key' "$SKILL/SKILL.md"
  grep -qiE 'top-level director' "$SKILL/SKILL.md"
}
