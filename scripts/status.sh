#!/usr/bin/env bash
# scripts/status.sh — multi-project dashboard. Spec §6.5.
# Usage: status.sh <project>      → one project
#        status.sh --all          → every configured project
#        status.sh                → every configured project (same as --all)

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

_print_one() {
  local project="$1"
  echo "── $project ──"
  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"

  if [[ -z "$active" || "$active" == "null" ]]; then
    echo "  Active: (idle)"
  else
    local cur cur_state cur_name
    if [[ -f "$issue_dir/checklist.md" ]]; then
      cur="$(checklist_current_step "$issue_dir/checklist.md")"
      if [[ "$cur" == "done" ]]; then
        echo "  Active: $active — all steps complete"
      else
        cur_state="$(checklist_step_state "$issue_dir/checklist.md" "$cur")"
        cur_name="$(checklist_step_name "$issue_dir/checklist.md" "$cur")"
        echo "  Active: $active — step $cur ($cur_name) [$cur_state]"
      fi
    else
      echo "  Active: $active — (no checklist.md)"
    fi
    if [[ -n "$issue_dir" && -f "$issue_dir/STUCK" ]]; then
      local reason
      reason="$(awk -F': *' '/^Reason:/{ $1=""; sub(/^ /,""); print; exit }' "$issue_dir/STUCK")"
      echo "  STUCK: $reason"
    fi
  fi

  local parked
  parked="$(state_list_parked "$project" | paste -sd, -)"
  if [[ -n "$parked" ]]; then echo "  Parked: $parked"; fi
}

main() {
  local mode="all"
  local project=""
  case "${1:-}" in
    --all) mode="all" ;;
    "")    mode="all" ;;
    *)     mode="one"; project="$1" ;;
  esac

  local -a projects=()
  mapfile -t projects < <(config_list_projects 2>/dev/null || true)
  if (( ${#projects[@]} == 0 )); then
    echo "No projects configured. Add one to ~/.claude/devagent/config.toml."
    return 0
  fi

  case "$mode" in
    one)
      config_is_project "$project" || die "status.sh: unknown project '$project'"
      _print_one "$project"
      ;;
    all)
      local p
      for p in "${projects[@]}"; do _print_one "$p"; done
      ;;
  esac
}

main "$@"
