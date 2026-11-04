#!/usr/bin/env bash
# scripts/quarantine-check.sh — the first action of every skill-backed step
# command (#714). Exits 0 silently, 11 on a quarantined issue (the fixed
# message on stderr), 9/10 on a trust refusal.
#
# Usage: quarantine-check.sh [project] [issue-id] [ignored…]
# The command's own $ARGUMENTS pass through: a first token that is not a
# configured project, and an issue token that is not a configured dir_prefix
# followed by digits (a free-form note), are ignored — the pin or the active
# issue is checked instead.

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
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"

project=""
if [ -n "${1:-}" ] && config_is_project "$1" 2>/dev/null; then
  active_resolve_project_try "$1" 2>/dev/null || true
  project="$1"
  shift
elif active_resolve_project_try "" 2>/dev/null; then
  project="$ACTIVE_RESOLVED_PROJECT"
fi
# no project: the command's own resolution reports it.
[ -n "$project" ] || exit 0
active_guard_scope quarantine-check
trust_entry_check "quarantine-check" "$project"
quarantine_guard "quarantine-check" "$project" "${1:-}"
