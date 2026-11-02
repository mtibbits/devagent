#!/usr/bin/env bash
# scripts/lib/trust-locate.sh — find the #711 trust policy (#713).
# No dependencies, so #902's first-command prologue can source it before any
# other library. It finds and reports; it never prints or refuses — the
# caller (trust.sh) does that. Safe to source multiple times.
#
# shellcheck shell=bash

# trust_locate --system <dir>… --user <dir>
#
# SETTER-GLOBAL — call it bare, never in $( … ). Sets:
#   TRUST_HOST          1 when a policy (or a defect) was found, else 0
#   TRUST_DIR           the location holding the policy (or the defect)
#   TRUST_SOURCE        system | user
#   TRUST_USER_IGNORED  the user location, when it holds a policy that a
#                       system policy shadows (doctor and pull's run record
#                       report it; no entry point prints it)
#   TRUST_EMPTY_DIRS    location dirs that exist with no policy.toml (doctor
#                       notes them; an empty dir is "no policy there")
#   TRUST_DEFECT        the reason, when a location is unusable
# Returns 1 on a defect (an unreadable dir, a dangling link, a non-directory),
# else 0. Every candidate is probed on every platform — never by OSTYPE — and
# no environment variable enters a path but HOME, which the caller expands.
# With nothing found it runs only [ -e ] / [ -L ] tests.
# shellcheck disable=SC2034  # setter-globals, read by the caller
trust_locate() {
  local sys=() user="" mode="" a
  for a in "$@"; do
    case "$a" in
      --system) mode=system ;;
      --user) mode=user ;;
      *) if [ "$mode" = system ]; then sys+=("$a"); else user="$a"; fi ;;
    esac
  done
  TRUST_HOST=0 TRUST_DIR="" TRUST_SOURCE="" TRUST_USER_IGNORED="" TRUST_DEFECT=""
  TRUST_EMPTY_DIRS=()
  local d
  for d in "${sys[@]}"; do
    _trust_probe "$d" || { TRUST_SOURCE=system; return 1; }
    if [ "$TRUST_HOST" = 1 ]; then
      TRUST_SOURCE=system
      # the user location, shadowed: reported, never read.
      if [ -n "$user" ] && { [ -e "$user/policy.toml" ] || [ -L "$user/policy.toml" ]; }; then
        TRUST_USER_IGNORED="$user"
      fi
      return 0
    fi
  done
  [ -n "$user" ] || return 0
  _trust_probe "$user" || { TRUST_SOURCE=user; return 1; }
  [ "$TRUST_HOST" = 1 ] && TRUST_SOURCE=user
  return 0
}

# _trust_probe <dir>: one candidate. Sets TRUST_HOST/TRUST_DIR when it holds a
# policy.toml entry (readable or not — load reports the file), appends an
# existing empty dir to TRUST_EMPTY_DIRS, returns 1 with TRUST_DEFECT set when
# the location itself is unusable.
# shellcheck disable=SC2034  # setter-globals, read by the caller
_trust_probe() {
  local d="$1"
  if [ -L "$d" ] && [ ! -e "$d" ]; then
    TRUST_HOST=1 TRUST_DIR="$d" TRUST_DEFECT="the location $d is a dangling link"
    return 1
  fi
  [ -e "$d" ] || return 0
  if [ ! -d "$d" ]; then
    TRUST_HOST=1 TRUST_DIR="$d" TRUST_DEFECT="the location $d is not a directory"
    return 1
  fi
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then
    TRUST_HOST=1 TRUST_DIR="$d" TRUST_DEFECT="the location $d cannot be read"
    return 1
  fi
  if [ -e "$d/policy.toml" ] || [ -L "$d/policy.toml" ]; then
    TRUST_HOST=1 TRUST_DIR="$d"
    return 0
  fi
  TRUST_EMPTY_DIRS+=("$d")
  return 0
}
