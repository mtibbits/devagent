#!/usr/bin/env bash
# scripts/where.sh — reports active issue + last/next step. Does NOT execute.
# Spec §6.5.

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

_report_parked() {
  local project="$1"
  local parked
  parked="$(state_list_parked "$project" | paste -sd, -)"
  [[ -n "$parked" ]] && echo "Parked: $parked"
  return 0
}

# _report_stall <issue_dir> <checklist> <found> (#880): print the STUCK: section
# for a stall checklist_sentinel_stall found (<found> = its `<line>:<step>`),
# naming the row's block even when it sits in an older revision block. Prints
# nothing for an empty <found>. Always returns 0 (safe as a bare call under
# set -e); callers branch on <found>.
_report_stall() {
  local issue_dir="$1" checklist="$2" found="$3"
  [[ -n "$found" ]] || return 0
  echo
  echo "STUCK:"
  echo "  [!] $(checklist_describe_row "$checklist" "${found%%:*}")"
  sed 's/^/  /' "$issue_dir/STUCK"
  echo
  echo "Run /devagent:unstuck to clear."
  return 0
}

main() {
  local project="${1:-}"
  [[ -n "$project" ]] || die "project required"
  config_require_project "$project"

  echo "Project: $project"

  # #240: session view — a pinned session's `where` reports ITS issue.
  local active issue_dir
  if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
    active="$(active_resolve_issue "$project" || true)"
  else
    active="$(state_get "$project" active_issue 2>/dev/null || true)"
  fi
  issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"

  if [[ -z "$active" || "$active" == "null" ]]; then
    echo "Active issue: (none)"
    echo "No active issue. Use /devagent:resume <issue> or /devagent:pull to begin."
    _report_parked "$project"
    return 0
  fi

  echo "Active issue: $active"
  [[ -n "$issue_dir" ]] || die "state.issue_dir missing for active issue"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "checklist.md missing at $checklist"

  local cur_step cur_state cur_name next_step next_name stall
  # #880: a STUCK [!] in ANY revision block, not only the current row.
  stall="$(checklist_sentinel_stall "$issue_dir")"
  cur_step="$(checklist_current_step "$checklist")"
  if [[ "$cur_step" == "done" ]]; then
    echo "All steps complete."
    _report_stall "$issue_dir" "$checklist" "$stall"
    _report_parked "$project"
    return 0
  fi
  cur_state="$(checklist_step_state "$checklist" "$cur_step")"
  cur_name="$(checklist_step_name "$checklist" "$cur_step")"
  echo "Current step: ${cur_step} (${cur_name}) [${cur_state}]"

  # If stuck, surface STUCK
  if [[ "$cur_state" == "!" && -f "$issue_dir/STUCK" ]]; then
    echo
    echo "STUCK:"
    sed 's/^/  /' "$issue_dir/STUCK"
    echo
    echo "Run /devagent:unstuck to clear."
    _report_parked "$project"
    return 0
  fi
  if [[ -n "$stall" ]]; then
    _report_stall "$issue_dir" "$checklist" "$stall"
    _report_parked "$project"
    return 0
  fi

  # Compute next actionable step
  next_step="$(checklist_next_actionable "$checklist" "$cur_step")"
  if [[ -n "$next_step" ]]; then
    next_name="$(checklist_step_name "$checklist" "$next_step")"
    echo "Next step: ${next_step} (${next_name})"
  fi

  echo
  echo "Run /devagent:next to execute the next step."
  _report_parked "$project"
}

main "$@"
