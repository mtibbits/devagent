#!/usr/bin/env bats
# bats file_tags=gitbash
# A fixture for tests/preship-deferred.bats (#1097): one test per guard form. It is
# committed to a scratch repository as tests/guards.bats and read as text at a pinned
# commit; nothing runs it. Each guard line is unique in this file: the tests find its
# line number by its text.

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# Git Bash on NTFS has no POSIX modes.
skip_on_git_bash() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "$1 (Git Bash: no POSIX file modes)" ;;
  esac
}

_one_line_skipper() { is_git_bash && skip "one-line helper"; }

function keyword_skipper {
  [[ "$(uname -s)" == MINGW* ]] && skip "keyword helper"
}

_inner_skipper() {
  is_git_bash && skip "inner helper"
}

_outer_caller() {
  _inner_skipper
}

_windows_only() {
  is_git_bash || skip "helper: Git Bash only"
}

# ---- the brief's table: must trip -------------------------------------------------

@test "trip: and-skip" {
  is_git_bash && skip "Git Bash: no POSIX folder modes"
  true
}

@test "trip: not-or-skip" {
  ! is_git_bash || skip "POSIX hosts only"
  true
}

@test "trip: one-line case arm" {
  case "$(uname -s)" in MINGW*|MSYS*) skip "no read-only directories on Windows" ;; esac
  true
}

@test "trip: multi-line case arm" {
  case "$(uname -s)" in
    MINGW*|MSYS*)
      skip "no symlinks without Developer Mode"
      ;;
  esac
  true
}

@test "trip: skipping helper" {
  local f=x
  skip_on_git_bash "chmod 000"
  true
}

# ---- the brief's table: must not trip ----------------------------------------------

@test "pass: or-skip" {
  is_git_bash || skip "Git Bash only (the drive-letter forms are relative paths elsewhere)"
  true
}

@test "pass: not-and-skip" {
  ! is_git_bash && skip "Windows only: POSIX has no sharing violation"
  true
}

@test "pass: uname equals MINGW or-skip" {
  [[ "$(uname -s)" == MINGW* ]] || skip "needs Git Bash"
  true
}

@test "pass: OSTYPE equals msys or-skip" {
  [ "$OSTYPE" = msys ] || skip
  true
}

@test "pass: if-not then skip" {
  if ! is_git_bash; then skip; fi
  true
}

@test "pass: case with an empty Git Bash arm" {
  case "$(uname -s)" in MINGW*|MSYS*) ;; *) skip "holding a file open is Windows-only" ;; esac
  true
}

@test "pass: reason names Git Bash" {
  [ /c/.. -ef / ] || skip "not Git Bash (/c/.. is not the MSYS root)"
  true
}

@test "pass: a comment" {
  # is_git_bash && skip "disabled while the port is in flight"
  true
}

@test "pass: the next test is guarded" {
  true
}

@test "trip: the guarded neighbour" {
  is_git_bash && skip "the neighbour's guard"
  true
}

# ---- documented misses: neither is seen -------------------------------------------

@test "miss: multi-line if block" {
  if is_git_bash; then
    skip "a block the check does not read"
  fi
  true
}

@test "miss: two-level helper" {
  _outer_caller
  true
}

# ---- more forms that must trip -----------------------------------------------------

@test "trip2: uname equals MINGW and-skip" {
  [[ "$(uname -s)" == MINGW* ]] && skip "bracket: skipped on Git Bash"
  true
}

@test "trip2: OSTYPE differs or-skip" {
  [ "$OSTYPE" != "msys" ] || skip "differs-or: skipped on Git Bash"
  true
}

@test "trip2: one-line if" {
  if is_git_bash; then skip "one-line if: skipped on Git Bash"; fi
  true
}

@test "trip2: Linux only" {
  [ "$(uname -s)" = Linux ] || skip "Linux only, so skipped on Git Bash"
  true
}

@test "trip2: a variable that only names MSYS" {
  [ "$MSYSTEM" = "" ] || skip "MSYSTEM is set on Git Bash"
  true
}

@test "trip2: second arm is a Git Bash arm" {
  case "$(uname -s)" in MINGW*) ;; MSYS*) skip "the MSYS arm skips" ;; esac
  true
}

@test "trip2: fall-through to the default arm" {
  case "$(uname -s)" in MINGW*|MSYS*) ;;& *) skip "every host falls through to here" ;; esac
  true
}

@test "trip2: a second case statement on the line" {
  case x in msys) ;; esac; case "$(uname -s)" in Linux) ;; *) skip "the second case skips off Linux" ;; esac
  true
}

@test "trip2: second skip on the line" {
  [ -n "${HOME:-}" ] || skip "no HOME"; is_git_bash && skip "the second skip on its line"
  true
}

@test "trip2: a safe skip, then one that is not" {
  is_git_bash || skip "the first is Git Bash only"; skip "the second runs on every host"
  true
}

@test "trip2: brace group" {
  is_git_bash && { skip "inside a brace group"; }
  true
}

@test "trip2: lower-case arm on its own line" {
  case "$OSTYPE" in
    msys*|cygwin*)
      skip "lower-case arm: skipped on Git Bash"
      ;;
  esac
  true
}

@test "trip2: one-line helper" {
  _one_line_skipper
  true
}

@test "trip2: function keyword helper" {
  keyword_skipper
  true
}

@test "trip2: a guard after a trailing comment mark inside quotes" {
  local hash="#"; is_git_bash && skip "the # above is quoted, not a comment"
  true
}

# ---- more forms that must not trip: one body, read in one call -------------------

@test "pass2: every form in which skip runs only off Git Bash" {
  # a quoted value
  [ "$OSTYPE" = "msys" ] || skip "quoted value: Git Bash only"
  # differs, and-skip
  [[ "$(uname -s)" != MINGW* ]] && skip "differs-and: Git Bash only"
  # not before the brackets, and inside them
  ! [ "$OSTYPE" = msys ] && skip "not-bracket: Git Bash only"
  [ ! "$OSTYPE" = msys ] && skip "not-inside: Git Bash only"
  # a regular expression
  [[ "$(uname -s)" =~ ^(MINGW|MSYS) ]] || skip "regex: Git Bash only"
  # the reason says skip; skip is quoted text; skip is part of a longer word
  is_git_bash || skip "Git Bash only; we skip elsewhere"
  echo "uname says skip it" >/dev/null
  echo "an escaped quote \" then is_git_bash && skip \" is still text" >/dev/null
  is_git_bash && skip_nothing_here=1
  is_git_bash && git rebase --skip 2>/dev/null
  # a trailing comment
  true   # is_git_bash && skip "a trailing comment is not code"
  # a case over several lines whose default arm skips
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
      skip "multi-line: Git Bash only"
      ;;
  esac
  # a skip that tests something else, and a helper that skips off Git Bash
  [ -x /usr/bin/flock ] || skip "no flock here"
  _windows_only
  # brace group, one-line if
  is_git_bash || { skip "brace group: Git Bash only"; }
  if [[ "$(uname -s)" != MINGW* ]]; then skip "if-differs: Git Bash only"; fi
  # another arm after the empty Git Bash arm
  case "$OSTYPE" in msys*) ;; linux*) skip "Linux arm: skipped on Linux only" ;; esac
  true
}
