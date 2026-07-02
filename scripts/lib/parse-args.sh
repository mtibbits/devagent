#!/usr/bin/env bash
# parse-args.sh — invocation grammar for /devagent:<verb> [project] [issue] [note...]
# Spec §6.1. Sets DA_PROJECT, DA_ISSUE, DA_NOTE in caller's scope.
# Requires paths.sh and io.sh sourced first. config.sh and state.sh are
# sourced internally — callers do not need to (and harmlessly may) re-source.

_PA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_PA_LIB_DIR/config.sh"
# shellcheck source=/dev/null
source "$_PA_LIB_DIR/state.sh"
# shellcheck source=/dev/null
source "$_PA_LIB_DIR/active.sh"

parse_devagent_args() {
  DA_PROJECT=""
  DA_ISSUE=""
  DA_NOTE=""

  # Split args into pre-separator and post-separator groups.
  local -a pre_sep=()
  local -a post_sep=()
  local seen_sep=0
  while (( $# > 0 )); do
    if [[ "$1" == "--" && $seen_sep -eq 0 ]]; then
      seen_sep=1
      shift
      continue
    fi
    if (( seen_sep )); then
      post_sep+=("$1")
    else
      pre_sep+=("$1")
    fi
    shift
  done

  local idx=0
  # Token 1: project? (must come before any --)
  if (( ${#pre_sep[@]} > idx )); then
    if config_is_project "${pre_sep[$idx]}"; then
      DA_PROJECT="${pre_sep[$idx]}"
      idx=$((idx + 1))
    fi
  fi

  # Token 2: issue? (must come before any --)
  if (( seen_sep == 0 && ${#pre_sep[@]} > idx )); then
    if [[ "${pre_sep[$idx]}" =~ ^Issue(-Fork)?-[0-9]+$ ]]; then
      DA_ISSUE="${pre_sep[$idx]}"
      idx=$((idx + 1))
    fi
  fi

  # Remaining pre-sep tokens + all post-sep tokens → note
  local -a note_tokens=()
  if (( ${#pre_sep[@]} > idx )); then
    note_tokens+=("${pre_sep[@]:$idx}")
  fi
  if (( ${#post_sep[@]} > 0 )); then
    note_tokens+=("${post_sep[@]}")
  fi
  if (( ${#note_tokens[@]} > 0 )); then
    DA_NOTE="${note_tokens[*]}"
  fi

  # Default project when omitted — #282: env pin first, then the _active.toml
  # pointer via active_get_project (matches active_resolve_project precedence).
  # Value deliberately unvalidated (no config_is_project), matching this
  # chain's prior behavior.
  if [[ -z "$DA_PROJECT" ]]; then
    local active=""
    if [[ -n "${DEVAGENT_ACTIVE_PROJECT:-}" ]]; then
      active="$DEVAGENT_ACTIVE_PROJECT"
    else
      active="$(active_get_project 2>/dev/null || true)"
    fi
    if [[ -n "$active" ]]; then
      DA_PROJECT="$active"
    else
      local -a all
      mapfile -t all < <(config_list_projects 2>/dev/null)
      if (( ${#all[@]} == 1 )); then
        DA_PROJECT="${all[0]}"
      fi
    fi
  fi

  # Default issue from active_issue for the resolved project
  if [[ -z "$DA_ISSUE" && -n "$DA_PROJECT" ]]; then
    local ai
    ai="$(state_get "$DA_PROJECT" active_issue 2>/dev/null || true)"
    if [[ -n "$ai" && "$ai" != "null" ]]; then DA_ISSUE="$ai"; fi
  fi
}
