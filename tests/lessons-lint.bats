#!/usr/bin/env bats

setup() {
  LINT="$BATS_TEST_DIRNAME/../scripts/lessons-lint.sh"
  TPL="$BATS_TEST_DIRNAME/../templates/lessonsLearned_template.md"
}

@test "lessons-lint: passes a file using only closed-taxonomy tags" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim one
- Tags: [actionable]
### claim two
- Tags: [norm, pattern]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: fails an off-taxonomy tag (#232, the Issue-78 case)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
- [process] A wide-blast change is de-risked by enumerating callers.
- [test-isolation] Found, not fixed: DEVAGENT_CONFIG_OVERRIDE wired to nothing.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *process* ]]
  [[ "$output" == *test-isolation* ]]
}

@test "lessons-lint: fails a structured entry with no tag line" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### untagged claim
- Evidence: something
- Consequence: something
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
}

@test "lessons-lint: ignores tags inside a comment block" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### real claim
- Tags: [reference]
<!--
### example to delete
- Tags: [bogus-tag]
-->
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: the canonical template passes (lint agrees with the format)" {
  run bash "$LINT" "$TPL"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: missing file is a usage error (exit 2)" {
  run bash "$LINT" "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
}
