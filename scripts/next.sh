#!/usr/bin/env bash
# scripts/next.sh — execute the next actionable step on the active issue.
# Spec §6.5, §7 (chaining), §8 (gates).
# Usage: next.sh <project> [--auto] [--through <step-name>] [-- <note...>]

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

# Canonical step ordering (spec §5.2). Indexed 0..20.
STEP_NAMES=(pull draft scope improve prune tighten branch implement
            quality document commit analyze draftmr review redmr
            ship mergetoall updatewbs impact lessonslearned cleanup)

# Steps owned by Plan 2 today (executed in-process here).
# Today: none — Plan 2 implements pull separately (already step 0), and
# all other workflow verbs ship in Plans 3/4. next.sh therefore prints a
# deferral message for those. When Plans 3/4 land they replace this map.
declare -A STEP_OWNER
for n in "${STEP_NAMES[@]}"; do STEP_OWNER["$n"]="deferred"; done

_step_name_to_index() {
  local target="$1" i
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_NAMES[$i]}" == "$target" ]] && { echo "$i"; return 0; }
  done
  return 1
}

main() {
  local project="" auto=0 through="" note=""
  local -a rest=()
  while (( $# > 0 )); do
    case "$1" in
      --auto)     auto=1; shift ;;
      --through)  through="${2:?--through requires a step name}"; shift 2 ;;
      --)         shift; note="$*"; break ;;
      *)          rest+=("$1"); shift ;;
    esac
  done
  if (( ${#rest[@]} > 0 )); then
    set -- "${rest[@]}"
  else
    set --
  fi

  project="${1:-}"
  [[ -n "$project" ]] || die "next.sh: project required"
  config_is_project "$project" || die "next.sh: unknown project '$project'"

  # Resolve chain target
  local chain_target_idx=""
  if (( auto == 1 )) && [[ -z "$through" ]]; then
    through="cleanup"
  fi
  if [[ -n "$through" ]]; then
    if ! chain_target_idx="$(_step_name_to_index "$through")"; then
      die "next.sh: unknown step '$through'"
    fi
    echo "chain target: $through (step $chain_target_idx)"
  fi

  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -z "$active" || "$active" == "null" ]]; then
    die "next.sh: No active issue for project '$project'"
  fi
  issue_dir="$(state_get "$project" issue_dir)"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "next.sh: checklist.md missing at $checklist"

  # Find current step. Plan 1's checklist_current_step returns "done" when
  # all steps are complete, the step number otherwise.
  local cur
  cur="$(checklist_current_step "$checklist")"
  if [[ "$cur" == "done" ]]; then
    echo "All steps complete on $active."
    return 0
  fi
  local cur_state
  cur_state="$(checklist_step_state "$checklist" "$cur")"
  if [[ "$cur_state" == "!" ]]; then
    echo "STUCK: step $cur is marked [!]. Run /devagent:unstuck to clear." >&2
    if [[ -f "$issue_dir/STUCK" ]]; then
      sed 's/^/  /' "$issue_dir/STUCK" >&2
    fi
    return 1
  fi
  if [[ "$cur_state" == "?" ]]; then
    warn "Step $cur is [?] blocked-on-external. Consider /devagent:park."
    return 0
  fi

  # Dispatch loop
  while :; do
    local name owner
    name="${STEP_NAMES[$cur]:-}"
    [[ -n "$name" ]] || die "next.sh: step index $cur out of range"
    owner="${STEP_OWNER[$name]}"

    case "$owner" in
      deferred)
        echo "step $cur ($name): deferred — implemented in a later plan; not yet wired"
        ( log_append "$issue_dir" "$name" "skipped by next.sh — owner plan not yet shipped${note:+ ($note)}" ) 2>/dev/null || true
        return 0
        ;;
      *)
        die "next.sh: BUG — unknown owner '$owner' for step $name"
        ;;
    esac
  done
}

main "$@"
