#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-impact"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-impact"
}

@test "core-impact passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-impact distinguishes quantifiable vs qualitative" {
  grep -qi 'quantif' "$SKILL/SKILL.md"
  grep -qi 'qualitat' "$SKILL/SKILL.md"
}

@test "core-impact writes to issue dir" {
  grep -q 'impact.md' "$SKILL/SKILL.md"
}

@test "core-impact fixture exists" {
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-impact step 6 runs cost-report with --project and --issue and records both line labels (#730)" {
  cmd="$(awk '/^6\. \*\*Workflow cost\.\*\*/ { f = 1 } f && /cost-report\.sh/ { print; exit }' "$SKILL/SKILL.md")"
  [ -n "$cmd" ]
  printf '%s\n' "$cmd" | grep -qF -- '--project <project>'
  printf '%s\n' "$cmd" | grep -qF -- '--issue <Issue-N>'
  grep -qF -- '- Workflow cost: <line>' "$SKILL/SKILL.md"
  grep -qF -- "- Workflow cost (unattributed to a project, may include other projects' work): <line>" "$SKILL/SKILL.md"
}
