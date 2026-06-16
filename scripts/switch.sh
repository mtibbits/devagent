#!/usr/bin/env bash
# scripts/switch.sh — sugar: park current, resume target.
# Usage: switch.sh <project> <issue-id>

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"

main() {
  local project="${1:-}"
  local target="${2:-}"
  [[ -n "$project" ]] || die "switch.sh: project required"
  [[ -n "$target"  ]] || die "switch.sh: target issue required"
  config_is_project "$project" || die "switch.sh: unknown project '$project'"

  # #142: validate the target BEFORE parking the current issue, mirroring
  # resume.sh's two preconditions — otherwise a bad target parks the current
  # issue then dies, leaving a half-applied switch (no active issue, previous
  # freshly [P]-marked) for the operator to repair by hand.
  local parked devdoc target_dir
  parked="$(state_list_parked "$project")"
  grep -qxF "$target" <<<"$parked" || die "switch.sh: '$target' not parked for $project"
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  target_dir="${devdoc%/}/$target"
  [[ -d "$target_dir" ]] || die "switch.sh: issue dir missing: $target_dir"

  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -n "$active" && "$active" != "null" && "$active" != "$target" ]]; then
    "$PLUGIN_ROOT/scripts/park.sh" "$project"
  fi
  "$PLUGIN_ROOT/scripts/resume.sh" "$project" "$target"
}

main "$@"
