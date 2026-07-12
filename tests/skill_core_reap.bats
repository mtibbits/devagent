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
  # #446: the invocation now goes through ${CLAUDE_PLUGIN_ROOT}, so the path is
  # quoted (`reap.sh" --dry-run`); tolerate both the bare and quoted forms.
  assert_file_grep "${CMD}" 'scripts/capture/reap\.sh"? --dry-run'
}

@test "core-reap: no workflow handoff boilerplate (#130)" {
  # Captures live in Captures/<slug>/ with no checklist.md and no step, so the
  # copied numbered-workflow handoff block is wrong here and must be deleted.
  run grep -q '## Completion handoff' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'continue on to /devagent' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'checklist\.md' "${SKILL}"
  [ "$status" -ne 0 ]
}
