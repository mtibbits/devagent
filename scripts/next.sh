#!/usr/bin/env bash
# scripts/next.sh — execute the next actionable step on the active issue.
# Spec §6.5, §7 (chaining), §8 (gates).
# Usage: next.sh [project] [--auto] [--through <step-name>] [-- <note...>]
#
# Authority is the issue's own checklist.md, not a hardcoded step table.
# Each issue's checklist may include or omit steps (e.g. a planning-only
# issue may have no "implement"/"analyze"); next.sh just looks at the
# first unchecked step in *this* checklist.
#
# Dispatch: if scripts/<step-name>.sh exists and is executable, exec it.
# Otherwise print "→ Run /devagent:<step-name>" so the calling model
# invokes the slash command (skill-backed steps), then re-invokes
# /devagent:next when the skill is done.

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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/active.sh"

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

  project="$(active_resolve_project "${1:-}")"
  config_is_project "$project" || die "next.sh: unknown project '$project'"
  active_set_project "$project"

  if (( auto == 1 )) && [[ -z "$through" ]]; then
    through="cleanup"
  fi

  # Validate --through against the actual checklist (the authority).
  if [[ -n "$through" ]]; then
    local _ai _idir _cl
    _ai="$(state_get "$project" active_issue 2>/dev/null || true)"
    if [[ -n "$_ai" && "$_ai" != "null" ]]; then
      _idir="$(state_get "$project" issue_dir 2>/dev/null || true)"
      _cl="$_idir/checklist.md"
      if [[ -f "$_cl" ]] && ! grep -qE "^- \[.\][[:space:]]+[0-9]+\.[[:space:]]+${through}([[:space:]]|$)" "$_cl"; then
        die "next.sh: unknown step '$through' (not present in $_cl)"
      fi
    fi
  fi

  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -z "$active" || "$active" == "null" ]]; then
    die "next.sh: No active issue for project '$project'"
  fi
  issue_dir="$(state_get "$project" issue_dir)"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "next.sh: checklist.md missing at $checklist"

  # Dispatch loop. Each iteration re-reads the checklist so script steps
  # that mark themselves complete cause the next iteration to advance.
  while :; do
    local cur
    cur="$(checklist_current_step "$checklist")"
    if [[ "$cur" == "done" ]]; then
      echo "All steps complete on $active."
      return 0
    fi

    local name
    name="$(checklist_step_name "$checklist" "$cur")" \
      || die "next.sh: could not read step name for $cur in $checklist"

    local cur_state
    cur_state="$(checklist_step_state "$checklist" "$cur")"
    if [[ "$cur_state" == "!" ]]; then
      echo "STUCK: step $cur ($name) is marked [!]. Run /devagent:unstuck to clear." >&2
      [[ -f "$issue_dir/STUCK" ]] && sed 's/^/  /' "$issue_dir/STUCK" >&2
      return 1
    fi
    if [[ "$cur_state" == "?" ]]; then
      warn "Step $cur ($name) is [?] blocked-on-external. Consider /devagent:park."
      return 0
    fi

    local script_path="$PLUGIN_ROOT/scripts/$name.sh"
    if [[ -x "$script_path" ]]; then
      # Script-backed step: exec it. The script marks the checkbox and logs.
      "$script_path" "$project" ${note:+-- "$note"}
      # If chaining and we've reached the target, stop.
      if [[ -n "$through" && "$name" == "$through" ]]; then
        return 0
      fi
      # Loop: re-read checklist and advance.
      continue
    else
      # Skill-backed step: hand back to the model.
      echo "→ Run /devagent:$name"
      echo "  (step $cur on this issue's checklist; skill-backed)"
      # If chaining is in effect, emit a CHAIN: marker (Plan 6 convention)
      # so the model knows to re-invoke /devagent:next after the skill
      # completes, continuing the chain until the through-target or a
      # checkpoint (stuck/blocked/permission gate). The skill itself is
      # responsible for marking the step done on success; this script's
      # next invocation re-reads the checklist and advances.
      if (( auto == 1 )) || [[ -n "$through" ]]; then
        local chain_cmd="/devagent:next"
        (( auto == 1 )) && chain_cmd+=" --auto"
        [[ -n "$through" ]] && chain_cmd+=" --through $through"
        echo "CHAIN: $chain_cmd"
      fi
      return 0
    fi
  done
}

main "$@"
