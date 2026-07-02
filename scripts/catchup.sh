#!/usr/bin/env bash
# scripts/catchup.sh — synthesise issue rehydration. Spec §6.5.
# Usage: catchup.sh <project> [issue-id]

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

_print_issue_title() {
  local issue_md="$1"
  if [[ -f "$issue_md" ]]; then
    head -n 1 "$issue_md"
  else
    echo "(issue.md missing)"
  fi
}

_print_last_two_comments() {
  local issue_md="$1"
  [[ -f "$issue_md" ]] || { echo "  (no issue.md)"; return; }
  # Extract every "### @user · date" header and the line after; keep last two.
  awk '
    /^### @/ { if (h) print h; h = $0; getline; getline body; sub(/^[[:space:]]*/, "", body); h = h " — " substr(body,1,120) }
    END { if (h) print h }
  ' "$issue_md" | tail -n 2 | sed 's/^/  /'
}

main() {
  local project="${1:-}"
  local issue_arg="${2:-}"
  [[ -n "$project" ]] || die "catchup.sh: project required"
  config_is_project "$project" || die "catchup.sh: unknown project '$project'"

  local issue issue_dir devdoc
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  if [[ -n "$issue_arg" ]]; then
    issue="$issue_arg"
    issue_dir="${devdoc%/}/$issue"
  else
    issue="$(state_get "$project" active_issue 2>/dev/null || true)"
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
    [[ -n "$issue" && "$issue" != "null" ]] \
      || die "catchup.sh: No active issue for $project; pass one explicitly."
  fi
  [[ -d "$issue_dir" ]] || die "catchup.sh: missing $issue_dir"

  echo "═══ Catchup: $project / $issue ═══"
  echo "Title: $(_print_issue_title "$issue_dir/issue.md")"

  if [[ -f "$issue_dir/checklist.md" ]]; then
    local cur cur_name
    cur="$(checklist_current_step "$issue_dir/checklist.md")"
    if [[ "$cur" == "done" ]]; then
      echo "Current step: (all complete)"
    else
      cur_name="$(checklist_step_name "$issue_dir/checklist.md" "$cur")"
      echo "Current step: $cur ($cur_name)"
      # #150: advisory model-tier for the current step (only when configured).
      # #291: issue_dir keeps the hint in agreement with the per-issue marker.
      local _tier
      if _tier="$(step_models_tier "$project" "$cur" "$issue_dir")"; then
        echo "  wants tier: $_tier"
      fi
    fi
  fi

  if [[ -f "$issue_dir/STUCK" ]]; then
    echo
    echo "STUCK file present:"
    sed 's/^/  /' "$issue_dir/STUCK"
  fi

  echo
  echo "── imPlan ──"
  if [[ -f "$issue_dir/imPlan.md" ]]; then
    head -n 20 "$issue_dir/imPlan.md" | sed 's/^/  /'
  else
    echo "  imPlan.md: not yet present (lands at step 1 draft)"
  fi

  echo
  echo "── actualWork ──"
  if [[ -f "$issue_dir/actualWork.md" ]]; then
    tail -n 20 "$issue_dir/actualWork.md" | sed 's/^/  /'
  else
    echo "  actualWork.md: not yet present (lands at step 9 document)"
  fi

  echo
  echo "── Last 2 comments ──"
  _print_last_two_comments "$issue_dir/issue.md"

  echo
  echo "── Last 5 log entries ──"
  log_tail "$issue_dir" 5 2>/dev/null | sed 's/^/  /' || true
}

main "$@"
