#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-scope"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-scope"
}

@test "devagent-scope passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-scope SKILL.md lists all 6 scope questions" {
  for q in "scope" "out of scope" "size" "ambiguity" "preconditions" "success"; do
    grep -qi "$q" "$SKILL/SKILL.md" || { echo "missing question: $q"; false; }
  done
}

@test "devagent-scope appends to Scope evaluation section" {
  grep -qE 'Scope evaluation' "$SKILL/SKILL.md"
}

@test "devagent-scope fixture: imPlan.md present" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/checklist.md" ]
}
