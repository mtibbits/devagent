#!/usr/bin/env bats
# #527: core-improve became a fork prompt bound to devagent:plan-improver
# (pattern-completing #458). The procedure-content pins that used to grep the
# SKILL now grep the agent system prompt — the procedure's single source; the
# skill-side assertions pin the fork shape and its purity (no second contract
# copy, no handoff block — those are the wrapper's).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-improve"
  AGENT="$BATS_TEST_DIRNAME/../agents/plan-improver.md"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-improve"
}

@test "core-improve passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "the improve procedure covers bugs, side effects, ambiguities (#527: in the agent)" {
  grep -qi 'bug' "$AGENT"
  grep -qi 'side effect' "$AGENT"
  grep -qi 'ambiguit' "$AGENT"
}

@test "the improve procedure carries the pothole tripwire and self-resolves the register (#286/#527)" {
  # The Checklist tripwire item.
  grep -qi 'Pothole register tripwire' "$AGENT"
  # #527/AC4: the agent resolves `potholes` ITSELF via the §12 walk — the
  # dead-tripwire class (#286: a checklist item the checker never RECEIVES)
  # is closed by construction, not by a packaging-list line that can rot.
  grep -q 'show potholes' "$AGENT"
  grep -q 'potholes' "$AGENT"
}

@test "core-improve is a pure fork prompt: no contract copy, no handoff (#527)" {
  run grep -c '^context: fork$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:plan-improver$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  # Wrapper duties must not leak back into the skill (twin-drift guard,
  # mirrors tests/dispatch-contract.bats' fork-skill sweep).
  run grep -c '## Dispatch contract' "$SKILL/SKILL.md"
  [ "$output" -eq 0 ]
  run grep -c 'step-model.sh' "$SKILL/SKILL.md"
  [ "$output" -eq 0 ]
  run grep -c '## Completion handoff' "$SKILL/SKILL.md"
  [ "$output" -eq 0 ]
}

@test "core-improve fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
