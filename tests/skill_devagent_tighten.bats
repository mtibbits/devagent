#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-tighten"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-tighten"
}

@test "devagent-tighten passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-tighten covers ordering, dependencies, file paths, test plan" {
  for k in 'ordering' 'dependenc' 'file path' 'test plan'; do
    grep -qi "$k" "$SKILL/SKILL.md" || { echo "missing: $k"; false; }
  done
}

@test "devagent-tighten fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/imPlan-potentialFutureEnhancements.md" ]
  [ -s "$FIXT/checklist.md" ]
}
