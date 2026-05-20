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

main() {
  local project="${1:-}"
  local target="${2:-}"
  [[ -n "$project" ]] || die "switch.sh: project required"
  [[ -n "$target"  ]] || die "switch.sh: target issue required"

  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -n "$active" && "$active" != "null" && "$active" != "$target" ]]; then
    "$PLUGIN_ROOT/scripts/park.sh" "$project"
  fi
  "$PLUGIN_ROOT/scripts/resume.sh" "$project" "$target"
}

main "$@"
