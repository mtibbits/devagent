#!/usr/bin/env bats
# bats file_tags=gitbash
# #1127 changelog_text (tests/lib/changelog-text.bash): CHANGELOG.md followed by every
# changelog.d/*.md entry file, the one reader for a test of changelog entries, so a pin
# passes before and after the release that moves its entry. The last two tests run a
# temp copy of scripts/changelog.py; under Git Bash that is the native Windows python3,
# so the LF claim runs there too.
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"
. "${BATS_TEST_DIRNAME}/lib/changelog-text.bash"

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

setup() {
  t="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$t"
}

# _tool: a temp tree holding a copy of the tool, whose ROOT is that tree.
_tool() {
  mkdir -p "$t/scripts" "$t/changelog.d"
  cp "$REPO/scripts/changelog.py" "$t/scripts/changelog.py"
}

@test "changelog_text: CHANGELOG.md alone when changelog.d/ is missing" {
  printf '# Changelog\n\n## [Unreleased]\n' > "$t/CHANGELOG.md"
  changelog_text "$t" > "$BATS_TEST_TMPDIR/out"
  cmp "$t/CHANGELOG.md" "$BATS_TEST_TMPDIR/out"
}

@test "changelog_text: every file ends in a newline, entry files in byte order" {
  mkdir -p "$t/changelog.d"
  printf 'head' > "$t/CHANGELOG.md"
  printf 'ten' > "$t/changelog.d/10.md"
  printf 'nine\n' > "$t/changelog.d/9.md"
  printf 'docs' > "$t/changelog.d/docs-pass.md"
  changelog_text "$t" > "$BATS_TEST_TMPDIR/out"
  printf 'head\nten\nnine\ndocs\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/out"
}

@test "changelog_text: only regular .md files directly in changelog.d/" {
  mkdir -p "$t/changelog.d/sub" "$t/changelog.d/dir.md"
  printf 'head\n' > "$t/CHANGELOG.md"
  printf 'kept\n' > "$t/changelog.d/1.md"
  printf 'notes\n' > "$t/changelog.d/notes.txt"
  printf 'nested\n' > "$t/changelog.d/sub/x.md"
  changelog_text "$t" > "$BATS_TEST_TMPDIR/out"
  printf 'head\nkept\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/out"
}

@test "changelog_text: a symlinked .md in changelog.d/ is not an entry" {
  is_git_bash && skip "Git Bash: ln -s copies the file instead of linking it without Developer Mode"
  mkdir -p "$t/changelog.d"
  printf 'head\n' > "$t/CHANGELOG.md"
  printf 'linked\n' > "$t/outside.md"
  ln -s "$t/outside.md" "$t/changelog.d/link.md"
  [ -L "$t/changelog.d/link.md" ]
  changelog_text "$t" > "$BATS_TEST_TMPDIR/out"
  printf 'head\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/out"
}

@test "changelog_text: a missing CHANGELOG.md fails" {
  mkdir -p "$t/changelog.d"
  printf -- '- **Added: x.** entry-token-1127\n' > "$t/changelog.d/1.md"
  run changelog_text "$t"
  [ "$status" -ne 0 ]
  [[ "$output" != *entry-token-1127* ]]
}

@test "a pin through changelog_text survives a release (#1127)" {
  _tool
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] — 2026-01-01\n\n- **Added: the start.** Old.\n' \
    > "$t/CHANGELOG.md"
  printf -- '- **Added: a pinned thing (#42).** token-only-in-entry-1127\n' > "$t/changelog.d/42.md"
  local cl
  cl="$(changelog_text "$t")"
  [[ "$cl" == *token-only-in-entry-1127* ]]
  run grep -c token-only-in-entry-1127 "$t/CHANGELOG.md"
  [ "$status" -eq 1 ]
  run python3 "$t/scripts/changelog.py" release 9.9.9 2026-12-01
  [ "$status" -eq 0 ]
  [ ! -e "$t/changelog.d/42.md" ]
  cl="$(changelog_text "$t")"
  [[ "$cl" == *token-only-in-entry-1127* ]]
  run grep -c token-only-in-entry-1127 "$t/CHANGELOG.md"
  [ "$status" -eq 0 ]
}

@test "release and preview write LF (#1127)" {
  _tool
  printf '# Changelog\r\n\r\n## [Unreleased]\r\n\r\n- **Fixed: carried.** One\r\n  wrapped.\r\n\r\n## [1.0.0] — 2026-01-01\r\n\r\n- **Added: the start.** Old.\r\n' \
    > "$t/CHANGELOG.md"
  printf -- '- **Added: crlf entry (#42).** Two\r\n  wrapped.\r\n' > "$t/changelog.d/42.md"
  python3 "$t/scripts/changelog.py" preview > "$t/preview.out"
  run grep -c 'crlf entry' "$t/preview.out"
  [ "$status" -eq 0 ]
  run grep -c $'\r' "$t/preview.out"
  [ "$status" -eq 1 ]
  run python3 "$t/scripts/changelog.py" release 9.9.9 2026-12-01
  [ "$status" -eq 0 ]
  run grep -c -F '## [9.9.9] — 2026-12-01' "$t/CHANGELOG.md"
  [ "$status" -eq 0 ]
  run grep -c $'\r' "$t/CHANGELOG.md"
  [ "$status" -eq 1 ]
}
