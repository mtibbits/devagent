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
  [[ -n "$project" ]] || die "project required"
  [[ -n "$issue"   ]] || die "issue id required"
  config_is_project "$project" || die "unknown project '$project'"

  # Refuse if not parked
  local parked
  parked="$(state_list_parked "$project")"
  if ! grep -qxF "$issue" <<<"$parked"; then
    die "'$issue' not parked for $project"
  fi

  local devdoc issue_dir
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  issue_dir="${devdoc%/}/$issue"
  [[ -d "$issue_dir" ]] || die "issue dir missing: $issue_dir"

  # Flip [P] back to [~]
  local checklist="$issue_dir/checklist.md"
  if [[ -f "$checklist" ]]; then
    # #587: mark the LINE that carries [P], not its step NUMBER. park.sh marks
    # the ACTIVE block, but a park that predates a /devagent:revise leaves the
    # [P] in an OLDER block whose number the new block REUSES - a number-keyed
    # mark then flipped the new block's pending twin and left the issue looking
    # parked in its own checklist while resume reported success.
    local found parked_row
    found="$(checklist_find_glyph_line "$checklist" P)"
    if [[ -n "$found" ]]; then
      parked_row="${found%%:*}"
      checklist_mark_line "$checklist" "$parked_row" "~"
    fi
    ( log_append "$issue_dir" "resume" "issue resumed" ) 2>/dev/null || true
  fi

  # #240: a pinned session resumes WITHOUT touching the shared slot. The
  # [context.<issue>] table is the live home — there is nothing to restore
  # and deleting it (state_context_restore's tail) would destroy the very
  # data the session is about to use. Flag-flip only.
  if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
    [[ "$issue" == "$DEVAGENT_ACTIVE_ISSUE" ]] \
      || die "session is pinned to ${DEVAGENT_ACTIVE_ISSUE} — a pinned resume resumes the PINNED issue (got '$issue'); unset the pin to manage other issues"
    state_context_has "$project" "$issue" 2>/dev/null \
      || warn "$issue: no per-issue context recorded (legacy park or fresh issue) — reads start from defaults; run /devagent:branch if a branch existed"
    state_remove_parked "$project" "$issue"
    state_remove_displaced "$project" "$issue"   # #415: it is active now — no stale marker
    local wt_pin note_pin=""
    wt_pin="$(state_issue_get "$project" "$issue" worktree_path 2>/dev/null || true)"
    if [[ -n "$wt_pin" ]] \
       && ! "${DEVAGENT_GIT:-git}" -C "$wt_pin" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      warn "$issue: worktree_path is no longer a usable git working tree: $wt_pin (removed out-of-band? left recorded — recreate it or re-run /devagent:branch before committing)"
      note_pin=" (worktree_path stale — see warning)"
    fi
    info "resumed $issue (issue-pinned session; shared active_issue untouched)${note_pin}"
    return 0
  fi

  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ "$active" == "$issue" ]]; then
    # Already active (legacy parked+active state): restoring would clobber
    # live context with a stale snapshot (#98). Drop the flag and the stale
    # snapshot; leave live state untouched.
    state_remove_parked "$project" "$issue"
    state_remove_displaced "$project" "$issue"   # #415: it is active now — no stale marker
    state_unset "$project" "context.${issue}"
    info "resumed $issue (already active; context unchanged)"
    return 0
  fi
  # A different unparked issue may still be active; snapshot its context
  # before restore clears the top level, matching pull.sh's displacement
  # guard (#98).
  if [[ -n "$active" && "$active" != "null" ]]; then
    state_context_save "$project" "$active"
    # #415: park + mark the displaced active so it is recoverable in turn via
    # resume/switch (both key on the parked flag) — mirrors pull's displacement.
    if state_context_has "$project" "$active"; then
      state_add_parked "$project" "$active"
      state_add_displaced "$project" "$active"
    fi
  fi

  state_remove_parked "$project" "$issue"
  # #317: promote + restore in ONE transaction (was: a #96 set_many promote
  # followed by state_context_restore's multi-transaction choreography — a
  # window where active_issue = NEW while the top level still held the OLD
  # issue's keys, laundered by the table-miss fallback under a concurrent
  # reader, or persisted by a crash).
  state_resume_promote_restore "$project" "$issue" "$issue_dir"

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
