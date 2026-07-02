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
  # #96: same tearing pair as pull.sh — one transaction.
  state_set_many "$project" str active_issue "$issue" str issue_dir "$issue_dir"
  state_context_restore "$project" "$issue"

  # #248: liveness-check the restored worktree_path. A git worktree removed
  # out-of-band (git worktree prune, rm -rf, disk cleanup, worktree-root
  # relocation) between park and resume leaves a dead path active. Without this,
  # resume reports clean success and the dead path only surfaces later at the
  # unguarded commit.sh:57-58 as a raw git error that doesn't name the cause.
  # Warn now (naming path + issue) and qualify the success line; leave the value
  # active so the issue still resumes (recreating/clearing it is out of scope).
  # Mirrors ship.sh's #148 `--is-inside-work-tree` check (catches a missing dir
  # AND a path that exists but is not a git tree). Empty worktree_path
  # (non-worktree projects) and live trees resume silently.
  local worktree_path resume_note=""
  worktree_path="$(state_get "$project" worktree_path 2>/dev/null || true)"
  if [[ -n "$worktree_path" ]] \
     && ! "${DEVAGENT_GIT:-git}" -C "$worktree_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "$issue: worktree_path is no longer a usable git working tree: $worktree_path (removed out-of-band? left active — recreate it or re-run /devagent:branch before committing)"
    resume_note=" (worktree_path stale — see warning)"
  fi
  info "resumed $issue${resume_note}"
}

main "$@"
