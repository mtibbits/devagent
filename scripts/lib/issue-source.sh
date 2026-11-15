#!/usr/bin/env bash
# scripts/lib/issue-source.sh — which issue tracker a command reads (#1099).
# Requires paths.sh, io.sh and config.sh sourced first.
#
# Every function here is NON-FATAL and returns through setter globals: call it
# bare, never inside $(...) (register Issue-120/282), and gate on its rc, never
# on ISRC_ERR being empty. Under `set -e` a bare nonzero call ends the caller,
# so callers write `fn args || die "$ISRC_ERR"` (Issue-589). Each function
# resets every global it owns at entry, so a stale value never leaks through.
#
#   issue_source_section <origin|fork>   prints issue_source | issue_source_fork
#   issue_source_configured <p> <origin|fork>
#       rc 0 iff [project.<p>.<section>] backend is non-empty (D1); rc 1 not
#       configured; rc 2 config unreadable.
#   issue_source_take_flag <arg>...      ISRC_FLAG (origin|fork|""), ISRC_REST
#       (every other arg, in order), ISRC_ERR. rc 0, or rc 2 + ISRC_ERR. Owns
#       ONLY --origin/--fork and their =value spellings; every other token —
#       other flags and origin/fork positionals included — passes through.
#   issue_source_default <p>             ISRC_DEFAULT (origin|fork|""), ISRC_RULE
#       (key|only|fallback|""), ISRC_ERR. rc 0 resolved, rc 1 bad key, rc 2
#       unreadable config (never a fallback: Issue-243, Issue-710).
#
# Default rule: [project.<p>] default_issue_source, else the only configured
# source, else origin.

issue_source_section() {
  case "$1" in
    origin) printf 'issue_source\n' ;;
    fork)   printf 'issue_source_fork\n' ;;
    *)      return 1 ;;
  esac
}

issue_source_configured() {
  local project="$1" section backend rc=0
  section="$(issue_source_section "$2")" || return 1
  backend="$(config_get_project_field "$project" "${section}.backend" 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 2
  backend="${backend//$'\r'/}"
  [[ "$rc" -eq 0 && -n "$backend" ]]
}

# Setter globals: read by the caller, so shellcheck sees them as unused.
# shellcheck disable=SC2034
issue_source_take_flag() {
  ISRC_FLAG=""
  ISRC_REST=()
  ISRC_ERR=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --origin|--fork)
        if [[ -n "$ISRC_FLAG" ]]; then
          ISRC_ERR="at most one of --origin, --fork may be given, got: '--${ISRC_FLAG}' and '${arg}'"
          break
        fi
        ISRC_FLAG="${arg#--}"
        ;;
      --origin=*|--fork=*)
        ISRC_ERR="--origin and --fork take no value, got: '${arg}'"
        break
        ;;
      *)
        ISRC_REST+=("$arg")
        ;;
    esac
  done
  if [[ -n "$ISRC_ERR" ]]; then
    ISRC_FLAG=""
    ISRC_REST=()
    return 2
  fi
  return 0
}

# shellcheck disable=SC2034
issue_source_default() {
  ISRC_DEFAULT=""
  ISRC_RULE=""
  ISRC_ERR=""
  local project="$1" val rc=0 crc
  val="$(config_get_project_field "$project" default_issue_source)" || rc=$?
  val="${val//$'\r'/}"
  if [[ "$rc" -eq 0 ]]; then
    case "$val" in
      origin|fork) ;;
      *)
        ISRC_ERR="[project.${project}] default_issue_source must be \"origin\" or \"fork\", got: '${val}'"
        return 1
        ;;
    esac
    crc=0
    issue_source_configured "$project" "$val" || crc=$?
    if [[ "$crc" -eq 2 ]]; then
      ISRC_ERR="could not read [project.${project}.$(issue_source_section "$val")] backend (config rc 2)"
      return 2
    fi
    if [[ "$crc" -ne 0 ]]; then
      ISRC_ERR="[project.${project}] default_issue_source = \"${val}\" but [project.${project}.$(issue_source_section "$val")] has no backend configured"
      return 1
    fi
    ISRC_DEFAULT="$val"
    ISRC_RULE="key"
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    ISRC_ERR="could not read [project.${project}] default_issue_source (config rc ${rc})"
    return 2
  fi
  # `get` is rc 1 for a table as well as for an absent key; get-list tells
  # them apart (rc 3 wrong type), so a table-valued key fails, never falls back.
  crc=0
  config_get_project_list "$project" default_issue_source >/dev/null 2>&1 || crc=$?
  if [[ "$crc" -eq 3 ]]; then
    ISRC_ERR="[project.${project}] default_issue_source must be \"origin\" or \"fork\", got a table"
    return 1
  fi

  local o=0 f=0
  issue_source_configured "$project" origin || o=$?
  issue_source_configured "$project" fork || f=$?
  if [[ "$o" -eq 2 || "$f" -eq 2 ]]; then
    ISRC_ERR="could not read [project.${project}] issue source backends (config rc 2)"
    return 2
  fi
  if [[ "$o" -ne 0 && "$f" -eq 0 ]]; then
    ISRC_DEFAULT="fork"
    ISRC_RULE="only"
  elif [[ "$o" -eq 0 && "$f" -ne 0 ]]; then
    ISRC_DEFAULT="origin"
    ISRC_RULE="only"
  else
    ISRC_DEFAULT="origin"
    ISRC_RULE="fallback"
  fi
  return 0
}
