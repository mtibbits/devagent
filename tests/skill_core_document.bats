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

@test "core-document-actual-work resolves actualWork_template via the §12 registry (#341)" {
  # The bypass this issue closes: the skill must carry an explicit "Resolve
  # template" step citing §12, not a bare ${CLAUDE_PLUGIN_ROOT} path, so
  # project/devdoc overrides are honored at step 9 (mirror of core-draft-mr).
  grep -qi 'Resolve template' "$SKILL/SKILL.md"
  grep -q '§12' "$SKILL/SKILL.md"
  # And it names the registry walk (project paths → devdoc → plugin).
  grep -qi 'project paths' "$SKILL/SKILL.md"
}

@test "devagent-document fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/git-changes.diff" ]
}
