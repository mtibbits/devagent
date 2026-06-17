#!/usr/bin/env bats

load 'helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/skills/core-capture/SKILL.md"

@test "core-capture: SKILL.md exists" {
  [ -f "${SKILL}" ]
}

@test "core-capture: frontmatter declares name and description" {
  assert_file_grep "${SKILL}" "^name: core-capture$"
  assert_file_grep "${SKILL}" "^description: "
}

@test "core-capture: documents the TYPE/SUBTYPE/TITLE/RECOMMENDATION contract" {
  assert_file_grep "${SKILL}" "TYPE: <issue\|epic\|multi-epic>"
  assert_file_grep "${SKILL}" "SUBTYPE:"
  assert_file_grep "${SKILL}" "TITLE:"
  assert_file_grep "${SKILL}" "RECOMMENDATION:"
}

@test "core-capture: lists all five issue subtypes" {
  for s in bug feature docs perf chore; do
    grep -wq "${s}" "${SKILL}" || { echo "missing subtype: ${s}"; false; }
  done
}

@test "core-capture: warns against silent multi-epic expansion" {
  assert_file_grep "${SKILL}" "(silently|surface the recommendation)"
}

@test "core-capture: no workflow handoff boilerplate (#130)" {
  # Captures live in Captures/<slug>/ with no checklist.md and no step, so the
  # copied numbered-workflow handoff block is wrong here and must be deleted.
  run grep -q '## Completion handoff' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'continue on to /devagent' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'checklist\.md' "${SKILL}"
  [ "$status" -ne 0 ]
}
