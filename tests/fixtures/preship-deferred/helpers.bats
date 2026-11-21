#!/usr/bin/env bats
# bats file_tags=gitbash
# A fixture for tests/preship-deferred.bats (#1097): a helper that skips on Git Bash
# must be found wherever it is defined. Each skipping helper here stands after
# something that once hid it: a function whose closing brace carries more than the
# brace, a function it is defined inside, a heredoc that holds half a definition, a
# test's local stub. Committed to a scratch repository as tests/helpers.bats and read
# as text at a pinned commit; nothing runs it.

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# ---- closing braces that carry a redirection, a command, a comment ------------------

_noisy() {
  echo "to stderr"
} >&2

_after_noisy_skipper() {
  is_git_bash && skip "helper defined after a redirected closing brace"
}

_exported() {
  echo "exported"
}; export -f _exported

_commented() {
  echo "commented"
} # the end of _commented

_quiet_one_line() { "$@"; } >/dev/null 2>&1

_after_those_skipper() {
  is_git_bash && skip "helper defined after three more closing braces"
}

# ---- a first statement on the line of the opening brace --------------------------------

_first_statement_skipper() { local reason=${1:-}
  is_git_bash && skip "helper whose first statement shares the brace's line"
}

_guard_on_the_brace_line() { is_git_bash && skip "helper whose guard shares the brace's line"
  true
}

# ---- a helper defined inside a function -----------------------------------------------

_definer() {
  _nested_skipper() {
    is_git_bash && skip "helper defined inside a function"
  }
}

# ---- a heredoc that holds half a definition ------------------------------------------

@test "a heredoc that holds half a definition" {
  cat > "$BATS_TEST_TMPDIR/half.sh" <<'SH'
  half() {
SH
  true
}

_after_heredoc_skipper() {
  is_git_bash && skip "helper defined after a heredoc's half definition"
}

@test "trip: a helper defined after a heredoc's half definition" {
  _after_heredoc_skipper
  true
}

@test "a block that closes at an indent" {
  [ -n "${VERBOSE:-}" ] && {
    echo "verbose"
  }
  true
}

# ---- a test's local stub, its closing brace redirected -------------------------------

@test "pass: a local stub with a redirected closing brace" {
  stub() {
    echo "quiet"
  } >/dev/null
  stub
  true
}

skip_on_git_bash() {
  is_git_bash && skip "$1 (Git Bash)"
}

@test "trip: a helper defined after a test's local stub" {
  skip_on_git_bash "chmod 000"
  true
}

# ---- the rows for the helpers above ---------------------------------------------------

@test "trip: a helper defined after a redirected closing brace" {
  _after_noisy_skipper
  true
}

@test "trip: a helper defined after three more closing braces" {
  _after_those_skipper
  true
}

@test "trip: a helper defined inside a function" {
  _nested_skipper
  true
}

@test "trip: a helper whose first statement shares the brace's line" {
  _first_statement_skipper "chmod 000"
  true
}

@test "trip: a helper whose guard shares the brace's line" {
  _guard_on_the_brace_line
  true
}

@test "pass: helpers whose closing brace carries more" {
  _noisy "a redirection"
  _exported "a command after a semicolon"
  _commented "a comment"
  _quiet_one_line true
  true
}
