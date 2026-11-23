#!/usr/bin/env bats
# bats file_tags=gitbash
# A fixture for tests/preship-deferred.bats (#1097): what the static check does NOT see.
# Every test here is skipped on Git Bash, and each is deferred all the same: these are
# the misses scripts/preship-deferred.sh lists, pinned so that closing one is a
# deliberate change. Committed to a scratch repository as tests/misses.bats and read as
# text at a pinned commit; nothing runs it.
load 'lib/skips-kept-elsewhere'

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# bats runs this before every test: no test calls it by name.
setup() {
  case "$BATS_TEST_DESCRIPTION" in *"in setup"*) is_git_bash && skip "skipped in setup" ;; esac
}

_returns_early_then_skips() {
  is_git_bash || return 0
  skip "the helper returned early on every other host"
}

# Helper shapes the reader does not register, or whose body it ends early.
_skip_gb_subshell() (
  is_git_bash && skip "a subshell body (bats cannot skip from one; the shape is the miss)"
)

skip-gb-hyphen() {
  is_git_bash && skip "a hyphenated name"
}

_skip_gb_blank()

{
  is_git_bash && skip "a blank line before the brace"
}

_noop() { :; }; _skip_gb_second() {
  is_git_bash && skip "a definition that does not start its line"
}

_skip_gb_closer() {
  { echo "a brace group"
} >&2
  is_git_bash && skip "after a closing brace with a redirection at the function's indent"
}

_skip_gb_heredoc() {
  cat >/dev/null <<'SH'
}
SH
  is_git_bash && skip "after a heredoc line holding a closing brace"
}

@test "miss: a skip in setup" {
  true
}

@test "miss: a helper from another file" {
  skip_unless_posix_modes "chmod 000"
  true
}

@test "miss: no line names Git Bash" {
  [ -n "${WINDIR:-}" ] && skip "a Windows host"
  [ "${OS:-}" = Windows_NT ] && skip "a Windows host, by another variable"
  command -v cygpath >/dev/null 2>&1 && skip "cygpath is on PATH"
  skip "todo"
}

@test "miss: a backslash continuation" {
  is_git_bash \
    && skip "the guard is on the line above"
  true
}

@test "miss: an early return" {
  is_git_bash || return 0
  skip "only Git Bash gets this far"
}

@test "miss: a helper that returns early" {
  _returns_early_then_skips
  true
}

@test "miss: a case over several lines, default arm" {
  case "$(uname -s)" in
    Linux|Darwin) ;;
    *)
      skip "POSIX hosts only"
      ;;
  esac
  true
}

@test "miss: a helper with a subshell body" {
  _skip_gb_subshell
  true
}

@test "miss: a helper with a hyphenated name" {
  skip-gb-hyphen
  true
}

@test "miss: a helper whose brace follows a blank line" {
  _skip_gb_blank
  true
}

@test "miss: a helper defined after another on its line" {
  _skip_gb_second
  true
}

@test "miss: a helper with a redirected closing brace before its guard" {
  _skip_gb_closer
  true
}

@test "miss: a helper with a heredoc brace before its guard" {
  _skip_gb_heredoc
  true
}

@test "miss: an extglob Git Bash arm on its own line" {
  case "$(uname -s)" in
    @(MINGW|MSYS)*)
      skip "an extglob arm" ;;
  esac
  true
}

@test "miss: a guard after a heredoc that holds a closing brace" {
  cat > "$BATS_TEST_TMPDIR/f.sh" <<'SH'
f() {
  echo hi
}
SH
  is_git_bash && skip "the body was read up to the heredoc's brace"
  true
}
