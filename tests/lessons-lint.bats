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

@test "lessons-lint: an empty bracket [] does not satisfy the tag requirement (#232 review L1)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim
- []
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
}

@test "lessons-lint: a multi-tag line flags only the off-taxonomy token (#232)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim
- Tags: [norm, bogus]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag [bogus]"* ]]
  [[ "$output" != *"tag [norm]"* ]]
}

@test "lessons-lint: fails an untagged flat-bullet file, naming it (#525)" {
  # Batch-11 shape: top-level bold bullets, no '### ' heading, zero tags. The
  # entry floor used to key only off '### ', so these passed vacuously (exit 0).
  cat > "$BATS_TEST_TMPDIR/batch11.md" <<'LL'
# Lessons learned — Issue-440

- **`user-invocable:false` gates the operator MENU only** — not model
  reachability. State it precisely.
- **Blast radius of a which-files-carry-X change:** grep the file-set BEFORE
  the edit; the guard update is Step 0.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/batch11.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *batch11.md* ]]
}

@test "lessons-lint: a flat-bullet entry tagged by a following Tags line passes (#525)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

- **A flat bold-bullet claim that carries a tag.**
- Tags: [actionable]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: an entry-less present file passes (#525)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — Issue-000

No entries recorded yet.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}
