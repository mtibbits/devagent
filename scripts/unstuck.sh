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
    *)         die "unknown flag '$2'" ;;
  esac

  [[ -n "$project" ]] || die "project required"
  config_is_project "$project" || die "unknown project '$project'"

  local issue_dir
  issue_dir="$(issue_context_dir "$project")"
  [[ -d "$issue_dir" ]] || die "no issue_dir"

  if [[ ! -f "$issue_dir/STUCK" ]]; then
    info "no STUCK file at $issue_dir/STUCK — nothing to clear"
    return 0
  fi

  local checklist="$issue_dir/checklist.md"
  # #587: find the LINE that actually carries [!] - ACTIVE revision block first,
  # else file-wide (#76) - and mark THAT line. Carrying only the step NUMBER out
  # of a file-wide scan and handing it to checklist_mark re-resolved the number
  # into the ACTIVE block, flipping that block's twin of a REUSED closeout number
  # while the real [!] survived and STUCK was deleted anyway (#558 r3
  # BLOCKING-2 shape, unfixed at this site until #587).
  local found row name
  found="$(checklist_find_glyph_line "$checklist" '!')"
  [[ -n "$found" ]] || die "STUCK file present but no [!] step in checklist"
  row="${found%%:*}"
  name="$(checklist_step_name_at_line "$checklist" "$row")"     || die "cannot read the step name at line $row of $checklist"

  local glyph=" "
  [[ "$mode" == "inprogress" ]] && glyph="~"
  # Fail-closed: checklist_mark_line dies unless the row really took the glyph,
  # so set -e stops before the STUCK sentinel is removed below.
  checklist_mark_line "$checklist" "$row" "$glyph"

  rm -f "$issue_dir/STUCK"
  log_append "$issue_dir" "$name" "unstuck — flipped to [$glyph]"
  info "cleared STUCK at $issue_dir; step ${found#*:} ($name) → [$glyph]"
}

main "$@"
