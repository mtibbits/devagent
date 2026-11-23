#!/usr/bin/env bats
# bats file_tags=gitbash
# A fixture for tests/preship-deferred-parse.bats (#1097): one more miss the static check is
# known to have, kept apart because it needs its own is_git_bash. The check reads
# `is_git_bash` as true on the job's host, whatever defines it. Here it is true on the
# MSYS flavour only, so on the job's host (MINGW64) the test below is skipped, and it is
# deferred all the same. Committed to a scratch repository as tests/misses-word.bats and
# read as text at a pinned commit; nothing runs it.

is_git_bash() { case "$(uname -s)" in MSYS*) return 0 ;; esac; return 1; }

@test "miss: is_git_bash taken at its word" {
  is_git_bash || skip "this file's is_git_bash is false on the job's host"
  true
}
