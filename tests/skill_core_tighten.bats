#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-tighten"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-tighten"
}

@test "core-tighten passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-tighten covers ordering, dependencies, file paths, test plan" {
  for k in 'ordering' 'dependenc' 'file path' 'test plan'; do
    grep -qi "$k" "$SKILL/SKILL.md" || { echo "missing: $k"; false; }
  done
}

@test "core-tighten fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/imPlan-potentialFutureEnhancements.md" ]
  [ -s "$FIXT/checklist.md" ]
}
