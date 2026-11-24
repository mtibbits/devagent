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

@test "core-scaffold: no workflow handoff boilerplate (#130)" {
  # Captures live in Captures/<slug>/ with no checklist.md and no step, so the
  # copied numbered-workflow handoff block is wrong here and must be deleted.
  run grep -q '## Completion handoff' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'continue on to /devagent' "${SKILL}"
  [ "$status" -ne 0 ]
  run grep -q 'checklist\.md' "${SKILL}"
  [ "$status" -ne 0 ]
}

# #1097: the required-check criterion.
@test "#1097 core-scaffold names required-checks.sh, the five cases and the criterion form" {
  local t p
  t="$(awk '/^## Required CI checks/{f=1; print; next} f && /^## /{exit} f' "${SKILL}" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$t" ] || { echo "no '## Required CI checks' section"; return 1; }
  for p in 'scripts/required-checks.sh" "$DEVAGENT_PROJECT"' '`summary`' \
           'drive-letter paths' 'MSYS path rewriting' 'native Windows python3' 'CRLF line endings' \
           'no POSIX file modes' 'carries the `gitbash` tag' 'has no Git Bash skip' 'is green at the merged head' \
           'does not apply'; do
    [[ "$t" == *"$p"* ]] || { echo "the section lacks: $p"; return 1; }
  done
}

@test "#1097 scaffold: step 3 names the block rule" {
  local t p
  t="$(awk '/^3\. /{f=1} /^4\. /{f=0} f' "${CMD}" | tr '\n' ' ' | tr -s ' ')"
  for p in 'required-checks.sh' '<!-- required-checks:' 'marker line' 'delete the marker line' 'non-zero exit'; do
    [[ "$t" == *"$p"* ]] || { echo "step 3 lacks: $p"; return 1; }
  done
}
