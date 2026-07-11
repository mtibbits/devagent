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

@test "core-improve carries the pothole tripwire and packages the register (#286)" {
  # The Checklist tripwire item (item 4).
  grep -qi 'Pothole register tripwire' "$SKILL/SKILL.md"
  # The dispatch-packaging input — a DISTINCT assertion (not subsumed by the
  # tripwire line) proving the checker RECEIVES the register (dead-tripwire fix).
  grep -qi 'register path is load-bearing' "$SKILL/SKILL.md"
  grep -q 'potholes' "$SKILL/SKILL.md"
}

@test "core-improve fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
