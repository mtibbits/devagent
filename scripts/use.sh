#!/usr/bin/env bash
# scripts/use.sh — workflow-adjacent verb (spec §6.5). Deliberately switches the
# global project pointer (~/.claude/devagent/state/_active.toml) from an argument.
# This is the ONE legitimate arg-driven pointer writer (#349): since #282 the
# pointer is otherwise written only by pointer/fallback-resolved next.sh, so on a
# multi-project install its value freezes. Does NOT execute a workflow step —
# prints the resolved state and invites /devagent:next.

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

main() {
  local project="${1:-}"
  [[ -n "$project" ]] || die "project required (usage: /devagent:use <project>)"
  # Validate BEFORE writing — active_set_project only checks non-empty, so an
  # unknown project would otherwise brick the pointer. config_require_project
  # prints the configured set and exits non-zero on an unknown name.
  config_require_project "$project"

  active_set_project "$project"
  echo "Active project → $project"

  # #434: in a DEVAGENT_ACTIVE_PROJECT-pinned session the env beats the pointer
  # (active.sh: env > pointer), so a bare command STILL resolves the pin — this
  # `use` switched the pointer for OTHER sessions but NOT this one. Warn so the
  # operator isn't misled into thinking their session switched. (Warn, not refuse:
  # the pointer write is still legitimate for other sessions; scripted callers see
  # an extra stderr line but an unchanged exit code.) A pin targeting the SAME
  # project is a no-op switch → no warning.
  if [[ -n "${DEVAGENT_ACTIVE_PROJECT:-}" && "$DEVAGENT_ACTIVE_PROJECT" != "$project" ]]; then
    warn "this session is env-pinned to '$DEVAGENT_ACTIVE_PROJECT'; the pointer change to '$project' affects other sessions only (env beats the pointer for this session)"
  fi
  echo

  # Resolved-state view — where.sh takes the project as an arg and handles a
  # project with no active issue gracefully.
  exec bash "$PLUGIN_ROOT/scripts/where.sh" "$project"
}

main "$@"
