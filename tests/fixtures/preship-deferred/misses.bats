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

@test "miss: a guard after a heredoc that holds a closing brace" {
  cat > "$BATS_TEST_TMPDIR/f.sh" <<'SH'
f() {
  echo hi
}
SH
  is_git_bash && skip "the body was read up to the heredoc's brace"
  true
}
