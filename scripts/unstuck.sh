#!/usr/bin/env bash
# scripts/unstuck.sh — clear STUCK file, flip [!] back. Spec §5.3, §6.5.
# Usage: unstuck.sh <project> [--pending]
#   default: flip to [~]; --pending flips to [ ].

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

main() {
  local project="${1:-}"
  local mode="inprogress"
  case "${2:-}" in
    --pending) mode="pending" ;;
    "")        ;;
    *)         die "unstuck.sh: unknown flag '$2'" ;;
  esac

  [[ -n "$project" ]] || die "unstuck.sh: project required"
  config_is_project "$project" || die "unstuck.sh: unknown project '$project'"

  local issue_dir
  issue_dir="$(issue_context_dir "$project")"
  [[ -d "$issue_dir" ]] || die "unstuck.sh: no issue_dir"

  if [[ ! -f "$issue_dir/STUCK" ]]; then
    info "no STUCK file at $issue_dir/STUCK — nothing to clear"
    return 0
  fi

  local checklist="$issue_dir/checklist.md"
  # Find the [!] step
  local stuck_step
  stuck_step="$(awk '
    match($0, /^- \[!\] +([0-9]+)\./, m) { print m[1]; exit }
  ' "$checklist")"
  [[ -n "$stuck_step" ]] || die "unstuck.sh: STUCK file present but no [!] step in checklist"

  local glyph=" "
  [[ "$mode" == "inprogress" ]] && glyph="~"
  checklist_mark "$checklist" "$stuck_step" "$glyph"

  local name
  name="$(checklist_step_name "$checklist" "$stuck_step")"
  rm -f "$issue_dir/STUCK"
  log_append "$issue_dir" "$name" "unstuck — flipped to [$glyph]"
  info "cleared STUCK at $issue_dir; step $stuck_step ($name) → [$glyph]"
}

main "$@"
