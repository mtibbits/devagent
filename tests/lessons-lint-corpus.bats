#!/usr/bin/env bats
# tests/lessons-lint-corpus.bats — the corpus walker (#594). Hermetic: every
# case builds its own fixture corpus, so the CI-visible half of the gate always
# has subjects (the real corpus lives in a repo CI never checks out).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  WALK="$BATS_TEST_DIRNAME/../scripts/lessons-lint-corpus.sh"
  ROOT="$BATS_TEST_TMPDIR/corpus"
  mkdir -p "$ROOT"
}

# clean_file <path> — a minimal lint-clean lessonsLearned.md.
clean_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '# Lessons learned' '' '### a structured claim' '- Tags: [pattern]' > "$1"
}

# red_file <path> <offending-line> — a file carrying one offending entry line.
red_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '# Lessons learned' '' "$2" > "$1"
}

@test "lessons-lint-corpus: three clean files pass and the summary names the subject count" {
  clean_file "$ROOT/proj/Issue-1/lessonsLearned.md"
  clean_file "$ROOT/proj/Issue-2/lessonsLearned.md"
  clean_file "$ROOT/other/Issue-3/lessonsLearned.md"
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned 3 files, 0 red, 0 could-not-run"* ]]
}

@test "lessons-lint-corpus: an untagged entry fails, naming the file and the finding" {
  clean_file "$ROOT/proj/Issue-1/lessonsLearned.md"
  red_file "$ROOT/proj/Issue-2/lessonsLearned.md" '- **An untagged claim.**'
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"proj/Issue-2/lessonsLearned.md"* ]]
  [[ "$output" == *"entry has no tag"* ]]
  [[ "$output" == *"scanned 2 files, 1 red"* ]]
}

@test "lessons-lint-corpus: an off-taxonomy tag fails, naming the token" {
  red_file "$ROOT/proj/Issue-1/lessonsLearned.md" '- [note] x'
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"off-taxonomy tag [note]"* ]]
}

@test "lessons-lint-corpus: an EMPTY subject set is rc 2, never a vacuous pass (Issue-151/439/613)" {
  mkdir -p "$ROOT/proj/Issue-1"
  echo "not a lessons file" > "$ROOT/proj/Issue-1/notes.md"
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no lessonsLearned.md files found"* ]]
}

@test "lessons-lint-corpus: a nonexistent root is rc 2" {
  run bash "$WALK" "$BATS_TEST_TMPDIR/no-such-root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such file or directory"* ]]
}

@test "lessons-lint-corpus: .git/ is pruned by PATH COMPONENT; a gitlab-notes/ sibling is still caught (Issue-591)" {
  clean_file "$ROOT/proj/Issue-1/lessonsLearned.md"
  red_file "$ROOT/.git/Issue-9/lessonsLearned.md" '- **A red file inside .git.**'
  red_file "$ROOT/gitlab-notes/Issue-9/lessonsLearned.md" '- **A red file beside .git.**'
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitlab-notes/Issue-9/lessonsLearned.md"* ]]
  [[ "$output" != *".git/Issue-9"* ]]
  [[ "$output" == *"scanned 2 files, 1 red"* ]]
}

@test "lessons-lint-corpus: a real bracket-leading-heading file passes untouched (devagent/Issue-536, verbatim head)" {
  mkdir -p "$ROOT/devagent/Issue-536"
  cat > "$ROOT/devagent/Issue-536/lessonsLearned.md" <<'LL'
# Lessons learned — Issue-536

### [pattern] Before extracting a block, ADD the test that covers the line the extraction could break — an unedited green suite only proves what the suite already pinned
Tags: refactor, coverage, equivalence, actionable
"branch.bats passes unedited" was offered as refactor-equivalence, but every worktree test INJECTED
`worktree_root`, so the `|| echo "$source_dir-wt"` fallback — the one line the extraction would have
broken — was uncovered. The defect would have shipped green. Task 0 added that coverage FIRST and
mutation-proved it catches the defect. Equivalence claims are bounded by coverage you have measured,
LL
  run bash "$WALK" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned 1 files, 0 red"* ]]
}

@test "lessons-lint-corpus: a FILE argument lints exactly that file (the cleanup-gate shape)" {
  clean_file "$ROOT/proj/Issue-1/lessonsLearned.md"
  red_file "$ROOT/proj/Issue-2/lessonsLearned.md" '- **An untagged sibling that must not be walked.**'
  run bash "$WALK" "$ROOT/proj/Issue-1/lessonsLearned.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned 1 files, 0 red"* ]]
}

@test "lessons-lint-corpus: a FILE argument is linted as given, whatever its basename" {
  red_file "$ROOT/proj/Issue-1/other-name.md" '- **An untagged claim.**'
  run bash "$WALK" "$ROOT/proj/Issue-1/other-name.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-name.md"* ]]
  [[ "$output" == *"entry has no tag"* ]]
}

@test "lessons-lint-corpus: a nonexistent FILE argument is rc 2" {
  run bash "$WALK" "$ROOT/proj/Issue-1/missing.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such file or directory"* ]]
}

@test "lessons-lint-corpus: a lint that COULD NOT RUN is rc 2, named, never folded into the red count" {
  clean_file "$ROOT/proj/Issue-1/lessonsLearned.md"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub: cannot lint" >&2' 'exit 2' > "$BATS_TEST_TMPDIR/stub-lint.sh"
  LESSONS_LINT="$BATS_TEST_TMPDIR/stub-lint.sh" run bash "$WALK" "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not lint"* ]]
  [[ "$output" == *"proj/Issue-1/lessonsLearned.md"* ]]
  [[ "$output" == *"scanned 1 files, 0 red, 1 could-not-run"* ]]
}

@test "lessons-lint-corpus: no argument is a usage error (rc 2)" {
  run bash "$WALK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
