#!/usr/bin/env bats
# #565: the UTF-8 locale resolver. bats decides test-name registration in
# bats-preprocess, a child process spawned before any test-file code runs, so a
# non-UTF-8 locale silently drops every @test name carrying a non-ASCII
# character. This resolver is what every bats-invoking surface pins itself with.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # shellcheck source=../scripts/lib/utf8-locale.sh
  . "$REPO/scripts/lib/utf8-locale.sh"
}

# #572: a negative assertion is vacuously satisfied by a missing function's 127.
@test "#565: utf8_locale_resolve is defined by scripts/lib/utf8-locale.sh" {
  run type -t utf8_locale_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "#565: resolver returns a locale under which U+2014 is ONE character" {
  UTF8_LOCALE=sentinel
  run utf8_locale_resolve
  [ "$status" -eq 0 ]
  utf8_locale_resolve
  [ -n "$UTF8_LOCALE" ]
  [ "$UTF8_LOCALE" != sentinel ]
  # Assert the CLAIM, not one spelling of it (#561): whatever token came back
  # must actually give bash multibyte character semantics.
  run env LC_ALL="$UTF8_LOCALE" bash -c 'e="$(printf "\xe2\x80\x94")"; printf "%s" "${#e}"'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "#565: resolver honours an ambient UTF-8 LC_ALL instead of overriding it" {
  export LC_ALL=en_US.UTF-8
  if ! env LC_ALL=en_US.UTF-8 bash -c 'e="$(printf "\xe2\x80\x94")"; [ "${#e}" -eq 1 ]'; then
    skip "en_US.UTF-8 not installed on this machine"
  fi
  utf8_locale_resolve
  [ "$UTF8_LOCALE" = "en_US.UTF-8" ]
}

@test "#565: resolver returns 1 (never exits) when no candidate is UTF-8-capable" {
  export DEVAGENT_UTF8_LOCALE_CANDIDATES="xx_XX.NOSUCH yy_YY.NOSUCH"
  unset LC_ALL LANG LC_CTYPE
  UTF8_LOCALE=sentinel
  run utf8_locale_resolve
  [ "$status" -eq 1 ]
  utf8_locale_resolve || true
  [ -z "$UTF8_LOCALE" ]
}

@test "#565: a C-locale child does NOT satisfy the resolver's own predicate" {
  # The planted control: proves the predicate above can fail at all, so the
  # success assertions are not vacuous. LC_ALL=C is used rather than an env
  # scrub because LC_ALL outranks LC_CTYPE and LANG both.
  run env -u LANG -u LC_CTYPE LC_ALL=C bash -c 'e="$(printf "\xe2\x80\x94")"; printf "%s" "${#e}"'
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}
