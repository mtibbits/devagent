# scripts/lib/utf8-locale.sh — resolve a locale under which bash treats a
# multibyte character as ONE character (#565).
#
# WHY this exists: bats encodes each @test name into a shell function name in
# `bats-preprocess` (bats_encode_test_name), iterating "${name:i:1}". In a
# single-byte locale that iterates BYTES, so U+2014 becomes the three units
# e2/80/94 — 0xe2 matches [[:alnum:]] and is appended RAW while 0x80/0x94 are
# hex-escaped, yielding a function name the sourced file never defines. bats
# then prints `unknown test name` and SKIPS the test while still counting it in
# the 1..N plan. bats-preprocess is a child process spawned BEFORE any test file
# or `load`ed helper executes, so no in-repo test-side export can fix this — the
# locale must be in the environment bats INHERITS. Measured both ways in
# Issue-565's analysis/2026-08-10-draft-locale-probe.txt (P1-P5).
#
# shellcheck shell=bash

# Sets the global UTF8_LOCALE. Setter-global rather than stdout because a
# resolver used in an `|| die` shape cannot live inside $( … ) (#120/#282).
# Returns 0 with UTF8_LOCALE set, or 1 with it empty.
utf8_locale_resolve() {
  UTF8_LOCALE=""
  local cand
  # Ambient first (an operator who pinned a UTF-8 locale keeps it), then the
  # portable built-ins. DEVAGENT_UTF8_LOCALE_CANDIDATES is a TEST-ONLY seam: it
  # is readable from any environment, so every production caller unsets it
  # before resolving (see run-suite.sh) rather than trusting that nobody
  # exported it.
  local candidates="${DEVAGENT_UTF8_LOCALE_CANDIDATES:-C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8}"
  # LC_ALL > LC_CTYPE > LANG is the precedence bash itself applies to character
  # semantics, so the ambient probes are tried in that order.
  # shellcheck disable=SC2086  # $candidates is a space-separated list; splitting is the point
  for cand in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}" $candidates; do
    [ -n "$cand" ] || continue
    # Behavioural probe, NOT `locale -a` membership: bash accepts an invalid
    # LC_ALL silently and falls back to single-byte semantics, which is exactly
    # the failure mode being removed. A UTF-8 locale gives ${#e} == 1.
    # (Measured need: the blessed WSL clone has C.UTF-8 but NOT en_US.UTF-8, so
    # a name-based check would pick a locale that does not work there.)
    # shellcheck disable=SC2016  # single quotes are required: the printf and
    # the length test must run in the CHILD, under $cand's locale, not here
    if env LC_ALL="$cand" LANG="$cand" bash -c \
         'e="$(printf "\xe2\x80\x94")"; [ "${#e}" -eq 1 ]' 2>/dev/null; then
      # shellcheck disable=SC2034  # UTF8_LOCALE IS the return channel
      # (setter-global, consumed by callers), not a local
      UTF8_LOCALE="$cand"
      return 0
    fi
  done
  return 1
}
