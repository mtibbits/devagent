#!/usr/bin/env bash
# scripts/resume.sh — reactivate a parked issue.
# Usage: resume.sh <project> <issue-id>

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
  [[ -n "$project" ]] || die "resume.sh: project required"
  [[ -n "$issue"   ]] || die "resume.sh: issue id required"
  config_is_project "$project" || die "resume.sh: unknown project '$project'"

  # Refuse if not parked
  local parked
  parked="$(state_list_parked "$project")"
  if ! grep -qxF "$issue" <<<"$parked"; then
    die "resume.sh: '$issue' not parked for $project"
  fi

  local devdoc issue_dir
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  issue_dir="${devdoc%/}/$issue"
  [[ -d "$issue_dir" ]] || die "resume.sh: issue dir missing: $issue_dir"

  # Flip [P] back to [~]
  local checklist="$issue_dir/checklist.md"
  if [[ -f "$checklist" ]]; then
    local parked_step
    parked_step="$(awk '
      match($0, /^- \[P\] +([0-9]+)\./, m) { print m[1]; exit }
    ' "$checklist")"
    [[ -n "$parked_step" ]] && checklist_mark "$checklist" "$parked_step" "~"
    ( log_append "$issue_dir" "resume" "issue resumed" ) 2>/dev/null || true
  fi

  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ "$active" == "$issue" ]]; then
    # Already active (legacy parked+active state): restoring would clobber
    # live context with a stale snapshot (#98). Drop the flag and the stale
    # snapshot; leave live state untouched.
    state_remove_parked "$project" "$issue"
    state_unset "$project" "context.${issue}"
    info "resumed $issue (already active; context unchanged)"
    return 0
  fi
  # A different unparked issue may still be active; snapshot its context
  # before restore clears the top level, matching pull.sh's displacement
  # guard (#98).
  if [[ -n "$active" && "$active" != "null" ]]; then
    state_context_save "$project" "$active"
  fi

  state_remove_parked "$project" "$issue"
  state_set "$project" active_issue "$issue"
  state_set "$project" issue_dir   "$issue_dir"
  state_context_restore "$project" "$issue"
  info "resumed $issue"
}

main "$@"
