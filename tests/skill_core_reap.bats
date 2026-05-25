#!/usr/bin/env bats

load 'helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/skills/core-reap/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)}/commands/reap.md"

@test "core-reap: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: core-reap$"
}

@test "core-reap: documents DECISIONS output block" {
  assert_file_grep "${SKILL}" "^DECISIONS:$"
  assert_file_grep "${SKILL}" "action: keep"
  assert_file_grep "${SKILL}" "action: discard"
}

@test "core-reap: forbids editing the source file" {
  assert_file_grep "${SKILL}" "(read-only on sources|Do not edit the source)"
}

@test "core-reap: warns against discarding STUCK candidates lightly" {
  assert_file_grep "${SKILL}" "STUCK"
}

@test "core-reap: slash command runs --dry-run first" {
  assert_file_grep "${CMD}" "scripts/capture/reap.sh --dry-run"
}
