#!/usr/bin/env bats
load 'lib/bats-helpers'

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-preship"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-preship"
  # #458: the skill is now a fork prompt. Its procedure lives in the bound agent
  # and its main-session protocol in the command wrapper — each assertion below
  # names the file that OWNS the contract, so a contract deleted in the move
  # fails here rather than passing by relocation.
  AGENT="$BATS_TEST_DIRNAME/../agents/preship-verifier.md"
  CMD="$BATS_TEST_DIRNAME/../commands/preship.md"
}

@test "core-preship passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-preship is bound to the preship-verifier agent, which cannot write (#458)" {
  run grep -c '^context: fork$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:preship-verifier$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  # The isolation is the agent's, and it is a denial — not a declaration.
  grep -qE '^disallowedTools:.*\bWrite\b' "$AGENT"
  grep -qE '^disallowedTools:.*\bEdit\b' "$AGENT"
  grep -qE '^effort:[[:space:]]+\S' "$AGENT"
  # No model pin — a pinned agent model defeats the #291 inherit escape (rc 2);
  # the step default is wrapper-carried. See tests/agents.bats for the measurement.
  run grep -c '^model:' <(skill_frontmatter "$AGENT")
  [ "$output" -eq 0 ]
}

@test "the preship verifications live in the agent system prompt (#458)" {
  grep -qi 'acceptance criteria' "$AGENT"
  grep -qi 'findings applied' "$AGENT"
  grep -qi 'push preview' "$AGENT"
  grep -qi 'preship-evidence.sh' "$AGENT"
}

@test "preship fails to [!] via checklist-stuck with the correct signature (#149/#458)" {
  # No step-number argument — the script marks the CURRENT step. The failure
  # protocol binds the MAIN session, so #458 homes it in the wrapper.
  grep -q 'checklist-stuck.sh" "$ISSUE_DIR" "preship:' "$CMD"
  grep -q '/devagent:unstuck' "$CMD"
}

@test "preship zero-diff auto-skip is fail-safe (#149/#458)" {
  grep -q 'zero_diff_classify' "$CMD"
  grep -qi 'indeterminate' "$CMD"
}

@test "preship writes the checker's returned artifact verbatim (#458)" {
  # The checker cannot write files; a main session that rewrites the verdict it
  # dislikes would reinstate the #101/#102 class this step exists to catch.
  grep -qi 'verbatim' "$CMD"
}

@test "core-preship fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "the preship spec-touch verification covers adds/renames/removals (#435/#458)" {
  # Lives with the procedure, in the agent system prompt.
  grep -qi 'spec-touch' "$AGENT"
  grep -qiE 'renam' "$AGENT"
  grep -qiE 'remov' "$AGENT"
  grep -qiE 'config key' "$AGENT"
  grep -qiE 'top-level director' "$AGENT"
}
