#!/usr/bin/env bats

load 'helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/skills/devagent-capture/SKILL.md"

@test "devagent-capture: SKILL.md exists" {
  [ -f "${SKILL}" ]
}

@test "devagent-capture: frontmatter declares name and description" {
  assert_file_grep "${SKILL}" "^name: devagent-capture$"
  assert_file_grep "${SKILL}" "^description: "
}

@test "devagent-capture: documents the TYPE/SUBTYPE/TITLE/RECOMMENDATION contract" {
  assert_file_grep "${SKILL}" "TYPE: <issue\|epic\|multi-epic>"
  assert_file_grep "${SKILL}" "SUBTYPE:"
  assert_file_grep "${SKILL}" "TITLE:"
  assert_file_grep "${SKILL}" "RECOMMENDATION:"
}

@test "devagent-capture: lists all five issue subtypes" {
  for s in bug feature docs perf chore; do
    grep -wq "${s}" "${SKILL}" || { echo "missing subtype: ${s}"; false; }
  done
}

@test "devagent-capture: warns against silent multi-epic expansion" {
  assert_file_grep "${SKILL}" "(silently|surface the recommendation)"
}
