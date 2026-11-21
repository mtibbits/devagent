#!/usr/bin/env bats
# bats file_tags=gitbash
# A fixture for tests/preship-deferred.bats (#1097): how a test is found by its name.
# Committed to a scratch repository as tests/names.bats and read as text at a pinned
# commit; nothing runs it.

@test "disk: C:/x and C:\\x exit 1 on Linux" {
  true
}

@test 'single: quoted with a \\ kept as written' {
  true
}

@test "says \"hi\" for \$1 and \`id\`" {
  true
}

@test "dup" {
  true
}

@test "dup" {
  true
}

@test "thrice" {
  true
}

@test 'thrice' {
  true
}

@test "thrice" {
  true
}

@test "shown twice: a\\b" {
  true
}

@test 'shown twice: a\b' {
  true
}

@test "one-liner" { true; }

@test "trailing blanks"   {
  true
}

@test "after trailing blanks" {
  is_git_bash && skip "the next test's guard"
  true
}

  @test "indented" {
  true
}

@test "long reason, cut inside a character" {
  is_git_bash && skip "0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789ééé and the rest of a long reason"
  true
}

@test "long reason, cut between characters" {
  is_git_bash && skip "abcdefghi abcdefghi abcdefghi abcdefghi abcdefghi abcdefghi abcdefghi abcdefghi abcdefghi ABCDEFGHIJ and the rest of a long reason"
  true
}

@test "--starts with a dash" {
  true
}
