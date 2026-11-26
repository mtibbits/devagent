#!/usr/bin/env bash
# scripts/stuck.sh — mark current step [!], write STUCK file. Spec §5.3, §6.5.
# Usage: stuck.sh <project> "<reason>"

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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/question-actions.sh"   # question_lock (#963)

# #963: main refuses to overwrite an operator question. The check and the STUCK write
# run under the question lock hold.sh takes while it creates STUCK, taken only
# when questions/ exists (an issue that never held gets no directory). A lock
# wait that runs out (its own stderr line is relayed) falls back to an
# unlocked read, so a real stop is never lost. The EXIT trap releases the lock
# and removes questions/ when it is left empty, as hold.sh does.
_STUCK_DIR=""
_stuck_exit() { set +e; question_unlock; rmdir "$_STUCK_DIR/questions" 2>/dev/null; return 0; }

main() {
  local project="${1:-}"
  local reason="${2:-}"
  [[ -n "$project" ]] || die "project required"
  [[ -n "$reason"  ]] || die "reason required (quote it)"
  config_is_project "$project" || die "unknown project '$project'"

trust_entry_check "stuck" "$project"
quarantine_guard "stuck" "$project"
  local issue_dir
  issue_dir="$(issue_context_dir "$project")"
  [[ -d "$issue_dir" ]] || die "no issue_dir; nothing to mark stuck"
  if [[ -d "$issue_dir/questions" ]]; then
    _STUCK_DIR="$issue_dir"
    trap _stuck_exit EXIT
    question_lock "$issue_dir" || true
  fi
  hold_guard stuck "$issue_dir"

  local checklist="$issue_dir/checklist.md"
  local cur cur_name last_good last_good_name
  cur="$(checklist_current_step "$checklist")"
  [[ -n "$cur" && "$cur" != "done" ]] \
    || die "no current step to mark stuck (issue is complete or empty)"
  cur_name="$(checklist_step_name "$checklist" "$cur")"

  # Walk back for "last good" — the last [x] step number strictly before cur.
  # (checklist_steps_with_glyph is mawk-safe; the < cur bound stays in bash.)
  local good_steps n
  good_steps="$(checklist_steps_with_glyph "$checklist" x)"
  while read -r n; do
    [[ -n "$n" ]] || continue
    (( n < cur )) && last_good="$n"
  done <<< "$good_steps"
  if [[ -n "$last_good" ]]; then
    last_good_name="$(checklist_step_name "$checklist" "$last_good")"
  fi

  checklist_mark "$checklist" "$cur" "!"

  local ts; ts="$(date '+%Y-%m-%d %H:%M')"
  {
    printf 'Step:        %s %s\n' "$cur" "$cur_name"
    printf 'Reason:      %s\n' "$reason"
    if [[ -n "$last_good" ]]; then
      printf 'Last good:   step %s %s\n' "$last_good" "${last_good_name:-}"
    fi
    printf 'Created:     %s\n' "$ts"
  } > "$issue_dir/STUCK"

  log_append "$issue_dir" "$cur_name" "stuck — $reason"
  info "marked step $cur ($cur_name) stuck — wrote $issue_dir/STUCK"
}

main "$@"
