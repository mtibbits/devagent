#!/usr/bin/env bats
load 'lib/bats-helpers'

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-redmr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-redmr"
  # #458: see skill_core_preship.bats — each assertion names the contract's owner.
  AGENT="$BATS_TEST_DIRNAME/../agents/redteam-reviewer.md"
  CMD="$BATS_TEST_DIRNAME/../commands/redmr.md"
}

@test "core-redmr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-redmr references redteam_mr template" {
  grep -q 'redteam_mr' "$SKILL/SKILL.md"
}

@test "core-redmr is bound to the redteam-reviewer agent, which cannot write (#458)" {
  run grep -c '^context: fork$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:redteam-reviewer$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  grep -qE '^disallowedTools:.*\bWrite\b' "$AGENT"
  grep -qE '^disallowedTools:.*\bEdit\b' "$AGENT"
  grep -qE '^effort:[[:space:]]+\S' "$AGENT"
  # No model pin — a pinned agent model defeats the #291 inherit escape (rc 2);
  # the step default is wrapper-carried. See tests/agents.bats for the measurement.
  run grep -c '^model:' <(skill_frontmatter "$AGENT")
  [ "$output" -eq 0 ]
}

@test "redmr classifies findings by severity, in the agent system prompt (#458)" {
  grep -qi 'blocking' "$AGENT"
  grep -qi 'severity' "$AGENT"
  # The statusreport-parsed count line is contract; it must survive the move.
  grep -qF 'B blocking, M major, m minor, I info' "$AGENT"
  grep -qF 'B blocking, M major, m minor, I info' "$CMD"
}

@test "core-redmr fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "the redmr spec-touch question covers adds/renames/removals (#435/#458)" {
  # Lives with the procedure, in the agent system prompt.
  grep -qi 'spec-touch' "$AGENT"
  # all three lag classes named
  grep -qiE 'add' "$AGENT"
  grep -qiE 'renam' "$AGENT"
  grep -qiE 'remov' "$AGENT"
  # the spec-relevant surfaces named
  grep -qiE 'config key' "$AGENT"
  grep -qiE 'top-level director' "$AGENT"
}
