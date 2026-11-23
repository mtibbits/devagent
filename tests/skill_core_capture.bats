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

@test "core-capture: points tier proposals at capture's propose step (#1101)" {
  assert_file_grep "${SKILL}" "Propose model tiers"
  assert_file_grep "${SKILL}" "after the draft body is written"
}

# #1097: the required-check criterion.
_rc_section() { awk '/^## Required CI checks/{f=1; print; next} f && /^## /{exit} f' "${SKILL}"; }

@test "#1097 core-capture names required-checks.sh, the five cases and the criterion form" {
  local t p
  t="$(_rc_section | tr '\n' ' ' | tr -s ' ')"
  [ -n "$t" ] || { echo "no '## Required CI checks' section"; return 1; }
  for p in 'scripts/required-checks.sh" "$DEVAGENT_PROJECT"' 'RECOMMENDATION' \
           'drive-letter paths' 'MSYS path rewriting' 'native Windows python3' 'CRLF line endings' \
           'no POSIX file modes' 'carries the `gitbash` tag' 'has no Git Bash skip' 'is green at the merged head' \
           'does not apply'; do
    [[ "$t" == *"$p"* ]] || { echo "the section lacks: $p"; return 1; }
  done
}

@test "#1097 core-capture and core-scaffold treat a non-zero required-checks.sh exit as stop-and-report" {
  local f t
  for f in "${SKILL}" "${REPO_ROOT}/skills/core-scaffold/SKILL.md"; do
    t="$(awk '/^## Required CI checks/{f=1; print; next} f && /^## /{exit} f' "$f" | tr '\n' ' ' | tr -s ' ')"
    [[ "$t" == *'non-zero exit'*'stop and report its stderr'* ]] || { echo "$f: no stop-and-report"; return 1; }
    [[ "$t" == *'never read it as "does not apply"'* ]] || { echo "$f: no never-read-as"; return 1; }
  done
}
