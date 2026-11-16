#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-draft-mr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-draftmr"
}

@test "core-draft-mr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-draft-mr references mr_template.md" {
  grep -q 'mr_template.md' "$SKILL/SKILL.md"
}

@test "core-draft-mr writes mr.md" {
  grep -qE '\bmr\.md\b' "$SKILL/SKILL.md"
}

@test "devagent-draftmr fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-draft-mr writes Related: disk:<N>, never Closes #<N>, for a disk issue (#1009)" {
  grep -qF 'write `Related: disk:<N>`, never `Closes #<N>`' "$SKILL/SKILL.md"
}

@test "core-draft-mr states the claim forms, the name-the-commit rule and (N new) (#1122)" {
  local f="$SKILL/SKILL.md" p
  for p in '`tests/x.bats` (27 tests)' '`: 14/14`' '`N/N bats`' '`N pytest`' '`N commits`' '`N files changed`' \
           "grep -cE '^[[:blank:]]*@test[[:blank:]]' <file>" '14/14 at `<sha>`' '`(N new)`' 'never `— N tests`' \
           'claims-check.sh' 'out of code spans'; do
    grep -qF -- "$p" "$f" || { echo "missing: $p"; return 1; }
  done
}
