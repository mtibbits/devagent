#!/usr/bin/env bash
# scripts/stuck.sh — mark current step [!], and write the STUCK header through
# stuck_write (scripts/lib/checklist.sh, #909). Spec §5.3, §6.5.
# Usage: stuck.sh <project> "<reason>"

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
source "$PLUGIN_ROOT/scripts/lib/active.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"

main() {
  local project="${1:-}"
  local reason="${2:-}"
  [[ -n "$project" ]] || die "project required"
  [[ -n "$reason"  ]] || die "reason required (quote it)"
  config_is_project "$project" || die "unknown project '$project'"

trust_entry_check "stuck" "$project"
quarantine_guard "stuck" "$project"
  local issue_dir
  issue_dir="$(issue_context_dir "$project")"
  [[ -d "$issue_dir" ]] || die "no issue_dir; nothing to mark stuck"

  local checklist="$issue_dir/checklist.md"
  local cur cur_name last_good
  cur="$(checklist_current_step "$checklist")"
  [[ -n "$cur" && "$cur" != "done" ]] \
    || die "no current step to mark stuck (issue is complete or empty)"
  cur_name="$(checklist_step_name "$checklist" "$cur")"

  # The last good step for the STUCK header (#909: the one walk, stuck_last_good).
  last_good="$(stuck_last_good "$checklist" "$cur")" \
    || die "could not read the last good step before $cur in $checklist"

  checklist_mark "$checklist" "$cur" "!"

  stuck_write "$issue_dir" "$cur" "$cur_name" "$reason" "$last_good" \
    || die "could not write $issue_dir/STUCK"

  log_append "$issue_dir" "$cur_name" "stuck — $reason"
  info "marked step $cur ($cur_name) stuck — wrote $issue_dir/STUCK"
}

main "$@"
