#!/usr/bin/env bash
# scripts/park.sh — park an issue; clears active_issue if it was active.
# Spec §5.1 [P], §6.5.
# Usage: park.sh <project> [issue-id]

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

main() {
  local project="${1:-}"
  local issue="${2:-}"
  [[ -n "$project" ]] || die "park.sh: project required"
  config_is_project "$project" || die "park.sh: unknown project '$project'"

  local active devdoc
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  if [[ -z "$issue" ]]; then
    [[ -n "$active" && "$active" != "null" ]] \
      || die "park.sh: no active issue and no issue arg"
    issue="$active"
  fi

  local issue_dir="${devdoc%/}/$issue"
  # A21: refuse a typo'd issue id. Parking a non-existent dir used to skip the
  # checklist mark but still write a [parked] entry, stranding junk that resume
  # can never satisfy. Dir-existence is now a precondition, not an optional branch.
  [[ -d "$issue_dir" ]] || die "park.sh: issue dir not found: $issue_dir (typo in issue id?)"
  local checklist="$issue_dir/checklist.md"
  if [[ -f "$checklist" ]]; then
    local cur
    cur="$(checklist_current_step "$checklist")"
    if [[ -n "$cur" && "$cur" != "done" ]]; then
      checklist_mark "$checklist" "$cur" "P"
    fi
    ( log_append "$issue_dir" "park" "issue parked" ) 2>/dev/null || true
  fi

  state_add_parked "$project" "$issue"
  if [[ "$active" == "$issue" ]]; then
    state_context_save "$project" "$issue"
    state_unset "$project" active_issue
    state_unset "$project" issue_dir
    state_context_clear "$project"
  fi
  info "parked $issue"
}

main "$@"
