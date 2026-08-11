# scripts/lib/utf8-locale.sh — resolve a locale under which bash treats a
# multibyte character as ONE character (#565).
#
# WHY this exists: bats encodes each @test name into a shell function name in
# `bats-preprocess`, a CHILD process spawned BEFORE any test file or `load`ed
# helper runs — so no test-side export can influence it, and the locale must be
# in the environment bats INHERITS. Without a UTF-8 locale the encoder walks the
# name byte-wise, and a non-ASCII @test name can then be registered under a
# function name that is never defined; bats reports `unknown test name` and
# SKIPS the test while still counting it in the 1..N plan.
#
# The full derivation — including why that silent skip bites on Git Bash/MSYS
# but not on glibc — is written out in ONE place: README, "Running the test
# suite". Do not restate it here; it drifted once already.
#
# shellcheck shell=bash

# utf8_locale_is_utf8 <locale> — true when a bash child under <locale> treats
# U+2014 as one character. Behavioural, NOT `locale -a` membership: bash accepts
# an invalid LC_ALL silently and falls back to single-byte semantics, which is
# the exact failure mode being removed. (Measured need: the blessed WSL clone
# has C.UTF-8 but NOT en_US.UTF-8, so a name-based check would pick a locale
# that does not work there.)
utf8_locale_is_utf8() {
  # shellcheck disable=SC2016  # single quotes required: the printf and the
  # length test must run in the CHILD, under $1's locale, not expand here
  env LC_ALL="$1" LANG="$1" bash -c \
    'e="$(printf "\xe2\x80\x94")"; [ "${#e}" -eq 1 ]' 2>/dev/null
}

# utf8_locale_resolve [candidate...] — set the global UTF8_LOCALE to the first
# candidate satisfying utf8_locale_is_utf8. Returns 0 with UTF8_LOCALE set, or
# 1 with it empty. Never exits.
#
# Setter-global rather than stdout because a resolver used in an `|| die` shape
# cannot live inside $( … ) (#120/#282). Candidates are ARGUMENTS rather than an
# environment variable: an ambient seam would oblige every production caller to
# scrub it, and the first caller that forgot would fail silently.
utf8_locale_resolve() {
  local cand tried=" "
  local -a candidates
  if [ "$#" -gt 0 ]; then
    # Explicit candidates are AUTHORITATIVE — they replace the ambient probes
    # rather than being appended to them, so a caller (or a test) that names a
    # list gets exactly that list and nothing inherited from the shell.
    candidates=( "$@" )
  else
    # LC_ALL > LC_CTYPE > LANG is the precedence bash applies to character
    # semantics, so ambient values are tried in that order before the fallbacks.
    candidates=( "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}"
                 C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8 )
  fi

  # shellcheck disable=SC2034  # UTF8_LOCALE is the return channel, not a local
  UTF8_LOCALE=""
  for cand in "${candidates[@]}"; do
    [ -n "$cand" ] || continue
    # The three ambient variables commonly hold the same value; dedupe so a
    # locale-empty box does not pay for identical probe children.
    case "$tried" in *" $cand "*) continue ;; esac
    tried="$tried$cand "
    if utf8_locale_is_utf8 "$cand"; then
      # shellcheck disable=SC2034  # the return channel again, at the assignment
      UTF8_LOCALE="$cand"
      return 0
    fi
  done
  return 1
}
