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

  active_resolve_project_src "${1:-}"
  project="$ACTIVE_RESOLVED_PROJECT"
  config_is_project "$project" || die "unknown project '$project'"
  # #572: refuse a wrong-scope chain BEFORE the pointer refresh below — a
  # mismatched bare invocation must neither dispatch nor move the pointer.
  active_guard_scope next
  # #282: only pointer/fallback-resolved runs refresh the pointer (rationale
  # at active_resolve_project_src).
  case "$ACTIVE_RESOLVED_FROM" in pointer|fallback) active_set_project "$project" ;; esac

  if (( auto == 1 )) && [[ -z "$through" ]]; then
    through="cleanup"
  fi

  # Validate --through against the actual checklist (the authority).
  if [[ -n "$through" ]]; then
    local _ai _idir _cl
    _ai="$(active_resolve_issue "$project" 2>/dev/null || true)"
    if [[ -n "$_ai" && "$_ai" != "null" ]]; then
      _idir="$(issue_context_dir "$project" 2>/dev/null || true)"
      _cl="$_idir/checklist.md"
      if [[ -f "$_cl" ]] && ! grep -qE "^- \[.\][[:space:]]+[0-9]+\.[[:space:]]+${through}([[:space:]]|$)" "$_cl"; then
        die "unknown step '$through' (not present in $_cl)"
      fi
    fi
  fi

  # #240: session view — an env-pinned session's bare `next` drives ITS issue.
  local active issue_dir
  if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
    active="$(active_resolve_issue "$project" 2>/dev/null || true)"
  else
    active="$(state_get "$project" active_issue 2>/dev/null || true)"
  fi
  if [[ -z "$active" || "$active" == "null" ]]; then
    die "No active issue for project '$project'"
  fi
  issue_dir="$(issue_context_dir "$project")"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "checklist.md missing at $checklist"

  # Dispatch loop. Each iteration re-reads the checklist so script steps
  # that mark themselves complete cause the next iteration to advance.
  while :; do
    # Before identifying the current step, check whether the chain target
    # is already complete. This guards skill-backed targets: after the
    # skill marks itself [x], the model re-invokes next.sh and we must
    # not advance into the next step. Script-backed targets stop below
    # via the post-exec check, so this branch is mainly for skills.
    if [[ -n "$through" ]]; then
      local _ts
      _ts="$(checklist_step_state "$checklist" \
        "$(grep -E "^- \[.\][[:space:]]+[0-9]+\.[[:space:]]+${through}([[:space:]]|$)" "$checklist" \
            | sed -E 's/^- \[.\][[:space:]]+([0-9]+)\..*/\1/' | head -n1)" 2>/dev/null || true)"
      if [[ "$_ts" == "x" || "$_ts" == "-" ]]; then
        echo "Chain target '$through' is complete; stopping."
        return 0
      fi
    fi

    local cur
    cur="$(checklist_current_step "$checklist")"
    if [[ "$cur" == "done" ]]; then
      echo "All steps complete on $active."
      return 0
    fi

    local name
    name="$(checklist_step_name "$checklist" "$cur")" \
      || die "could not read step name for $cur in $checklist"

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

    # #150: advisory model-tier hint for the dispatched step. Prints only when the
    # optional [project.<name>.step_models] table resolves a tier; absent ⇒ silent.
    # #291: issue_dir passed so the hint agrees with the per-issue marker the
    # dispatch will actually resolve. #561: the marker's KEYED form covers the
    # thinking class too, so this hint now surfaces marker tiers for thinking
    # steps as well — and for the inline ones (9/10/11/14) the hint is the ONLY
    # place the tier appears, since a session cannot swap its own model.
    # DECISION (#561 review F5): a MALFORMED marker stays LOUD here. The `if`
    # swallows the rc but not the stderr, so step_models_tier's die message
    # prints on every next/catchup while the flow continues. That is wanted:
    # silencing it would hide a broken marker at exactly the moment the operator
    # is looking at the step list, and pull.sh's write-time validation means a
    # malformed marker can only arrive by hand-edit.
    local _tier
    if _tier="$(step_models_tier "$project" "$cur" "$issue_dir")"; then
      echo "step $cur ($name) wants tier: $_tier"
    fi

    local script_path="$PLUGIN_ROOT/scripts/$name.sh"
    if [[ -x "$script_path" ]]; then
      # Script-backed step: exec it. The script marks the checkbox and logs.
      # When chaining (and not at the target), suppress the script's
      # "Would you like to continue on to /devagent:X?" question so the
      # dispatcher's loop can run the next step without operator input.
      local chain_intends_continue=0
      if (( auto == 1 )) || [[ -n "$through" ]]; then
        if [[ -z "$through" || "$name" != "$through" ]]; then
          chain_intends_continue=1
        fi
      fi
      # Notes travel via the NOTE env var — the protocol the dispatched
      # workflow scripts already read (${NOTE:+...}). Passing the note
      # positionally as `-- "$note"` would land in the script's $2, which
      # every script parses as the issue arg (#123). NOTE="$note" is one
      # token regardless of spaces; empty when no note (downstream-safe).
      if (( chain_intends_continue == 1 )); then
        DEVAGENT_CHAIN_ACTIVE=1 NOTE="$note" "$script_path" "$project"
      else
        NOTE="$note" "$script_path" "$project"
      fi
      # If chaining and we've reached the target, stop.
      if [[ -n "$through" && "$name" == "$through" ]]; then
        return 0
      fi
      # #558: ADVANCE GUARD. The loop assumes a script step marks its own row,
      # so a step that exits 0 WITHOUT marking makes the next iteration
      # re-dispatch the same row — an unbounded loop with no cap (observed:
      # commit.sh marking a renumbered row on an older checklist re-ran
      # thousands of times, writing a log line each pass). Re-read the current
      # step; if the dispatched script left it unchanged, stop loudly instead
      # of spinning. Failing here is always better than a runaway: the step
      # either genuinely did nothing, or marked the WRONG row.
      local after
      after="$(checklist_current_step "$checklist" 2>/dev/null || true)"
      if [[ "$after" == "$cur" ]]; then
        die "step $cur ($name) exited 0 but did not mark itself — refusing to re-dispatch (would loop). Its script may have marked a different row: on a checklist predating the #558 renumber, migrate with scripts/migrate-checklist-numbering.sh or start a fresh revision with /devagent:revise."
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
        # #578: bake the RESOLVED project into the continuation. Without it every
        # hop re-resolves global state at fire time, so a concurrent session that
        # moves the pointer silently redirects the rest of the chain. The
        # script-backed path above already passes "$project"; this restores the
        # same invariant on the skill-backed path.
        local chain_cmd="/devagent:next $project"
        (( auto == 1 )) && chain_cmd+=" --auto"
        [[ -n "$through" ]] && chain_cmd+=" --through $through"
        echo "CHAIN: $chain_cmd"
      fi
      return 0
    fi
  done
}

main "$@"
