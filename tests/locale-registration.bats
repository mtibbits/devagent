#!/usr/bin/env bats
# #565: bats encodes each @test name into a shell function name in
# `bats-preprocess`, a CHILD process spawned before any test-file or `load`ed
# helper code runs. The encoder walks the name one unit at a time and either
# appends a unit RAW (when it matches [[:alnum:]]) or hex-escapes it.
#
# In a single-byte locale a multibyte character is walked BYTE-wise, and what
# happens next is PLATFORM-DEPENDENT — measured on both, 2026-08-11
# (analysis/2026-08-11-u2-nesting-and-platform.txt):
#
#   MSYS / Git Bash : 0xe2 IS [[:alnum:]] -> appended raw -> $'test_..\342-80-94..'
#                     a name the sourced file never defines -> bats prints
#                     `unknown test name` and SKIPS the test while still
#                     counting it in the 1..N plan. THE SILENT SKIP.
#   glibc / Linux   : 0xe2 is NOT [[:alnum:]] -> hex-escaped -> test_..-e2-80-94..
#                     produced identically on both sides -> the test REGISTERS.
#
# So the drop bites on Git Bash, not on Linux. The tests below assert BOTH
# branches, so this file is non-vacuous on either platform.
#
# DELIBERATELY does NOT source tests/lib/hermetic-env.bash, breaking the #322
# convention that every bare-setup bats file sources it. hermetic-env exports
# LC_ALL=C.UTF-8 into each test subprocess; sourcing it here would make the
# canary below read UTF-8 semantics in EVERY locale, leaving that guard
# permanently vacuous with nothing reddening. If a convention sweep adds that
# source line, the fire-proof test at the bottom is what fails. Do not "fix" it.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FIXTURE="$REPO/tests/fixtures/locale/nonascii.bats"

setup() {
  # shellcheck source=../scripts/lib/utf8-locale.sh
  . "$REPO/scripts/lib/utf8-locale.sh"
}

# Is this platform's single-byte locale one where the encoder emits a RAW high
# byte? That is the whole mechanism, probed directly rather than by
# reimplementing bats_encode_test_name (which would drift from it).
_emits_raw_high_byte() {
  env -u LANG -u LC_CTYPE LC_ALL=C bash -c \
    'em="$(printf "\xe2\x80\x94")"; b="${em:0:1}"; [[ "$b" =~ [[:alnum:]] ]]'
}

@test "#565: under the resolved locale ALL of the fixture's tests register" {
  utf8_locale_resolve
  [ -n "$UTF8_LOCALE" ]
  run env LC_ALL="$UTF8_LOCALE" LANG="$UTF8_LOCALE" bats --tap "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
  [[ "$output" != *"unknown test name"* ]]
  # Assert the COUNT, not mere absence of the error (#32) — counted from the run
  # above rather than re-spawning bats over the same fixture.
  [ "$(printf '%s
' "$output" | grep -c '^ok ')" = "2" ]
}

# Both verdict classes are asserted, so neither platform gets a silently
# vacuous pass (#Fork-162). Which branch ran is echoed into the TAP comments so
# a reader can tell what was actually exercised.
@test "#565: a single-byte locale drops the non-ASCII names exactly where the encoder emits a raw byte" {
  if _emits_raw_high_byte; then
    echo "# platform: MSYS-shaped (0xe2 is [[:alnum:]] in C) — expecting the DROP"
    run env -u LC_ALL -u LC_CTYPE -u LANG bats --tap "$FIXTURE"
    [[ "$output" == *"1..2"* ]]
    [[ "$output" == *"unknown test name"* ]]
    [ "$(printf '%s
' "$output" | grep -c '^ok ')" = "0" ]
  else
    echo "# platform: glibc-shaped (0xe2 is not [[:alnum:]] in C) — expecting NO drop"
    run env -u LC_ALL -u LC_CTYPE -u LANG bats --tap "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown test name"* ]]
    [ "$(printf '%s
' "$output" | grep -c '^ok ')" = "2" ]
  fi
}

# The locale IS load-bearing on every platform: the encoded form differs between
# a UTF-8 and a single-byte locale everywhere, which is why the runner pins it
# rather than inheriting whatever the invoking shell had.
@test "#565: a UTF-8 locale and a single-byte locale classify the character differently" {
  run env LC_ALL=C.UTF-8 bash -c 'em="$(printf "\xe2\x80\x94")"; printf "%s" "${#em}"'
  [ "$output" = "1" ]
  run env -u LANG -u LC_CTYPE LC_ALL=C bash -c 'em="$(printf "\xe2\x80\x94")"; printf "%s" "${#em}"'
  [ "$output" = "3" ]
}

# The canary that makes a BARE `bats tests/` in a locale-empty shell fail loudly
# instead of running silently thinner. Under run-suite.sh and CI this always
# passes, because both pin the locale. The `bats-locale-canary` token in the
# name is the filter handle the fire-proof below uses — keep it unique to THIS
# test, or the fire-proof recurses into itself.
@test "#565 bats-locale-canary: THIS bats process has UTF-8 character semantics" {
  e="$(printf '\xe2\x80\x94')"
  [ "${#e}" -eq 1 ] || {
    echo "This bats run has no UTF-8 locale (LC_ALL='${LC_ALL:-<unset>}' LC_CTYPE='${LC_CTYPE:-<unset>}' LANG='${LANG:-<unset>}')." >&2
    echo "That is the documented run condition for this suite, and on Git Bash / MSYS it" >&2
    echo "SILENTLY SKIPS every @test name containing a non-ASCII character while still" >&2
    echo "printing a full plan. (On glibc the same names still register — the skip is an" >&2
    echo "MSYS property — but the suite is only ever measured under a pinned locale.)" >&2
    echo "Re-run via: bash scripts/run-suite.sh <project>   — or export LC_ALL=C.UTF-8" >&2
    echo "See README 'Running the test suite'." >&2
    false
  }
}

# A guard proven to fire is only half-proven the other way round too: this
# executes the canary in a locale-empty child and asserts it REDDENS. Without
# it, sourcing hermetic-env.bash here (or any other change that pins the locale
# in-process) would silently make the canary unfalsifiable (#Fork-195).
@test "#565: the process-locale guard is proven to redden in a locale-empty run" {
  run env -u LC_ALL -u LC_CTYPE -u LANG bats -f 'bats-locale-canary' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"1..1"* ]]
  [[ "$output" == *"no UTF-8 locale"* ]]
}
