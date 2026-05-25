#!/usr/bin/env bats

load 'helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/skills/core-redissue/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/commands/redissue.md"

@test "core-redissue: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: core-redissue$"
}

@test "core-redissue: documents Blocking/Recommended/Nits sections" {
  assert_file_grep "${SKILL}" "### Blocking"
  assert_file_grep "${SKILL}" "### Recommended"
  assert_file_grep "${SKILL}" "### Nits"
}

@test "core-redissue: documents verdict triad" {
  grep -qF 'Verdict: ship | revise | split' "${SKILL}" || { echo "missing verdict triad"; false; }
}

@test "core-redissue: forbids editing draft.md" {
  assert_file_grep "${SKILL}" "Do not edit .draft.md"
}

@test "core-redissue: slash command writes redteam.md next to draft" {
  assert_file_grep "${CMD}" "redteam.md"
  assert_file_grep "${CMD}" "draft.md"
}
