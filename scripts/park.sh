#!/usr/bin/env bash
# scripts/park.sh — park an issue; clears active_issue if it was active.
# Spec §5.1 [P], §6.5.
# Usage: park.sh <project> [issue-id] [--reason <text>]
# --reason (#962): one non-empty line, appended to the park's log entry. A third
# positional is refused: /devagent:park passes $ARGUMENTS unquoted, so an
# unquoted multi-word reason would otherwise overflow into it.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/active.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"

_park_usage() {
  echo "park.sh: usage: park.sh <project> [issue-id] [--reason <text>]" >&2
  exit 2
}

main() {
  local project="" issue="" reason=""
  local -a pos=()
  while (( $# )); do
    case "$1" in
      --reason)
        # A blank reason is refused below, so a set one means a repeated flag.
        (( $# >= 2 )) && [[ -z "$reason" ]] || _park_usage
        reason="$2"
        [[ -n "${reason//[[:space:]]/}" && "$reason" != *$'\n'* && "$reason" != *$'\r'* ]] || _park_usage
        shift 2 ;;
      --*) _park_usage ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  (( ${#pos[@]} <= 2 )) || _park_usage
  project="${pos[0]:-}"
  issue="${pos[1]:-}"
  [[ -n "$project" ]] || die "project required"
  config_is_project "$project" || die "unknown project '$project'"

trust_entry_check "park" "$project"
quarantine_guard "park" "$project" "$issue"
  local active devdoc
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  if [[ -z "$issue" ]]; then
    # #240: a pinned session's bare park means ITS issue, not the shared one
    # (the active == issue gate below then naturally skips the shared-slot
    # writes when they are not its own).
    if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
      issue="$(active_resolve_issue "$project")" \
        || die "could not resolve the pinned issue"
    else
      [[ -n "$active" && "$active" != "null" ]] \
        || die "no active issue and no issue arg"
      issue="$active"
    fi
  fi

  local issue_dir="${devdoc%/}/$issue"
  # A21: refuse a typo'd issue id. Parking a non-existent dir used to skip the
  # checklist mark but still write a [parked] entry, stranding junk that resume
  # can never satisfy. Dir-existence is now a precondition, not an optional branch.
  [[ -d "$issue_dir" ]] || die "issue dir not found: $issue_dir (typo in issue id?)"
  local checklist="$issue_dir/checklist.md"
  if [[ -f "$checklist" ]]; then
    local cur was name entry="issue parked"
    # #962: an issue held on an operator question keeps its `[?]` row — no row
    # is marked `[P]`, so the question's row stays the one the hold marked.
    if [[ "$(stuck_kind "$issue_dir")" != question ]]; then
      cur="$(checklist_current_step "$checklist")"
      if [[ -n "$cur" && "$cur" != "done" ]]; then
        was="$(checklist_step_state "$checklist" "$cur" 2>/dev/null || true)"
        name="$(checklist_step_name "$checklist" "$cur" 2>/dev/null || true)"
        checklist_mark "$checklist" "$cur" "P"
        # #962: the earlier mark is recorded so hold.sh can return the row to it.
        [[ -z "$was" || -z "$name" ]] || entry+=" (row $cur $name was [$was])"
      fi
    fi
    [[ -z "$reason" ]] || entry+=": $reason"
    ( log_append "$issue_dir" "park" "$entry" ) 2>/dev/null || true
  fi

  state_add_parked "$project" "$issue"
  # #415: an operator park is BY DEFINITION not a displacement — clear any stale
  # displacement marker so a later re-pull GCs this park (fresh start, #98 MAJ-1)
  # instead of resurrecting old context. Load-bearing: closes the MAJ-1 hole at
  # the consumption point regardless of how a marker might have leaked in.
  state_remove_displaced "$project" "$issue"
  if [[ "$active" == "$issue" ]]; then
    state_context_save "$project" "$issue"
    state_unset "$project" active_issue
    state_unset "$project" issue_dir
    state_context_clear "$project"
  fi
  info "parked $issue"
}

main "$@"
