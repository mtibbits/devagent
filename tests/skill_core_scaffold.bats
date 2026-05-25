#!/usr/bin/env bats

load 'helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/skills/core-scaffold/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/commands/scaffold.md"

@test "core-scaffold: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: core-scaffold$"
}

@test "core-scaffold: documents CHILDREN output block" {
  assert_file_grep "${SKILL}" "^CHILDREN:$"
  assert_file_grep "${SKILL}" "subtype:"
  assert_file_grep "${SKILL}" "title:"
  assert_file_grep "${SKILL}" "summary:"
}

@test "core-scaffold: caps children and surfaces overflow" {
  assert_file_grep "${SKILL}" "OVERFLOW:"
}

@test "core-scaffold: slash command refuses non-epic drafts" {
  assert_file_grep "${CMD}" "# Epic:"
  assert_file_grep "${CMD}" "/devagent:capture epic"
}

@test "core-scaffold: slash command requires --force when children/ exists" {
  grep -qF -- '--force' "${CMD}" || { echo "missing --force in command"; false; }
}
