#!/usr/bin/env bats
# #565: the UTF-8 locale resolver. bats decides test-name registration in
# bats-preprocess, a child process spawned before any test-file code runs, so a
# non-UTF-8 locale can silently drop @test names carrying non-ASCII characters.
# This resolver is what every bats-invoking surface pins itself with.
# Mechanism: README, "Running the test suite".

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # shellcheck source=../scripts/lib/utf8-locale.sh
  . "$REPO/scripts/lib/utf8-locale.sh"
}

# #572: a negative assertion is vacuously satisfied by a missing function's 127.
@test "#565: the resolver and its predicate are defined by scripts/lib/utf8-locale.sh" {
  run type -t utf8_locale_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
  run type -t utf8_locale_is_utf8
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "#565: utf8_locale_is_utf8 accepts a UTF-8 locale and rejects a single-byte one" {
  # The planted control lives here: it proves the predicate can FAIL, so every
  # assertion built on it below is non-vacuous.
  run utf8_locale_is_utf8 C.UTF-8
  [ "$status" -eq 0 ]
  run utf8_locale_is_utf8 C
  [ "$status" -eq 1 ]
  run utf8_locale_is_utf8 xx_XX.NOSUCH
  [ "$status" -eq 1 ]
}

@test "#565: resolver returns a locale that satisfies its own predicate" {
  # No `run` here: `run` executes in a subshell, so the setter-global would be
  # discarded and the resolver would have to be called twice.
  utf8_locale_resolve
  [ -n "$UTF8_LOCALE" ]
  # Assert the CLAIM, not one spelling of it (#561), via the shared predicate.
  utf8_locale_is_utf8 "$UTF8_LOCALE"
}

@test "#565: resolver honours an ambient UTF-8 LC_ALL instead of overriding it" {
  export LC_ALL=en_US.UTF-8
  utf8_locale_is_utf8 en_US.UTF-8 || skip "en_US.UTF-8 not installed on this machine"
  utf8_locale_resolve
  [ "$UTF8_LOCALE" = "en_US.UTF-8" ]
}

@test "#565: explicit candidates are authoritative and never inherit the shell's" {
  # Ambient is deliberately left set: explicit arguments must REPLACE it, or a
  # caller naming a list could still be answered from the environment.
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
  UTF8_LOCALE=sentinel
  # `if !` rather than `run`: run's subshell would discard the setter-global,
  # and a bare failing call would abort the test under bats' errexit.
  if utf8_locale_resolve xx_XX.NOSUCH yy_YY.NOSUCH; then
    echo "resolver accepted a bogus candidate: $UTF8_LOCALE" >&2
    false
  fi
  [ -z "$UTF8_LOCALE" ]
}

@test "#565: resolver returns 1 (never exits) when no candidate is UTF-8-capable" {
  unset LC_ALL LANG LC_CTYPE
  UTF8_LOCALE=sentinel
  if utf8_locale_resolve xx_XX.NOSUCH; then
    echo "resolver accepted a bogus candidate: $UTF8_LOCALE" >&2
    false
  fi
  [ -z "$UTF8_LOCALE" ]
}
