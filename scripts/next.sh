#!/usr/bin/env bash
# scripts/next.sh — execute the next actionable step on the active issue.
# Spec §6.5, §7 (chaining), §8 (gates).
# Usage: next.sh [project] [--auto] [--through <step-name>] [--no-breaks] [-- <note...>]
#   (--chained is appended by next.sh itself to every CHAIN: line; see phase breaks)
#
# Authority is the issue's own checklist.md, not a hardcoded step table.
# Each issue's checklist may include or omit steps (e.g. a planning-only
# issue may have no "implement"/"analyze"); next.sh just looks at the
# first unchecked step in *this* checklist.
#
# Dispatch: every step is preceded by a "dispatch: <project>/<issue> — step N
# (<name>), <backing>" header. If scripts/<step-name>.sh exists and is
# executable and is not a step-named helper (#812), exec it.
# Otherwise print "→ Run /devagent:<step-name> <project>"
# so the calling model invokes the slash command (skill-backed steps), then
# re-invokes "/devagent:next <project> ..." from the emitted CHAIN: line when
# the skill is done. Both emissions carry the resolved project (#578).
#
# Phase breaks: a chain stops before each step named in `phase_breaks` (project
# field, else [defaults], else "implement quality updatewbs"; "" disables) so the
# next phase starts in a fresh session. One session per issue re-reads its whole
# history on every call: Issue-660's main context grew 49K→845K tokens over 386
# calls, and replaying it with fresh sessions at these three steps cut its cost
# ~56%. A break fires only for a CONTINUED chain — a CHAIN: re-invocation
# (--chained) or a script step already dispatched in this process — so the
# operator's first command in the fresh session runs the boundary step.

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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/ci.sh"

# phase_breaks <project> — the step names a continued chain stops before, one
# space-separated line. An empty value is a legal "no breaks".
phase_breaks() {
  local v
  if v="$(config_get_project_field "$1" phase_breaks 2>/dev/null)"; then
    printf '%s\n' "$v"
  elif v="$(config_get_default phase_breaks 2>/dev/null)"; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "implement quality updatewbs"
  fi
}

# #812: scripts that carry a workflow step's NAME but are helpers its slash
# command calls with their own verbs (`spike.sh create|teardown`), not the
# step's entry point; spec §6.3 types those steps `command`/`skill`.
# tests/next-backing.bats fails when a new helper collides with a step name;
# add such a helper HERE.
STEP_NAMED_HELPERS=" spike "

# step_backing <step-name> <script-path>: prints `script-backed` or
# `skill-backed`. The ONE backing decision: the dispatch header and the exec
# branch both read it.
step_backing() {
  if [[ "$STEP_NAMED_HELPERS" != *" $1 "* && -x "$2" ]]; then
    echo script-backed
  else
    echo skill-backed
  fi
}

main() {
  local project="" auto=0 through="" note="" chained=0 breaks_on=1
  local -a rest=()
  while (( $# > 0 )); do
    case "$1" in
      --auto)      auto=1; shift ;;
      --through)   through="${2:?--through requires a step name}"; shift 2 ;;
      --chained)   chained=1; shift ;;
      --no-breaks) breaks_on=0; shift ;;
      --)          shift; note="$*"; break ;;
      *)           rest+=("$1"); shift ;;
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

  # The operator's own chain flags, for a phase break's resume line. --auto's
  # implied target (cleanup, which every CHAIN: line spells out) is left implied.
  local resume_flags=""
  (( auto == 1 )) && resume_flags+=" --auto"
  if [[ -n "$through" ]] && { (( auto == 0 )) || [[ "$through" != cleanup ]]; }; then
    resume_flags+=" --through $through"
  fi
  (( breaks_on == 0 )) && resume_flags+=" --no-breaks"

  if (( auto == 1 )) && [[ -z "$through" ]]; then
    through="cleanup"
  fi
  local chaining=0 breaks=""
  if (( auto == 1 )) || [[ -n "$through" ]]; then
    chaining=1
    (( breaks_on == 1 )) && breaks=" $(phase_breaks "$project") "
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

  # #782: at most one CI read per invocation (see the window block below).
  local ci_done=0

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
    # #885: a [?] mergemr row is a wait on the PR, resumed by re-running the step
    # (it re-reads and marks itself); every other [?] keeps the park hint.
    if [[ "$cur_state" == "?" && "$name" != mergemr ]]; then
      warn "Step $cur ($name) is [?] blocked-on-external. Consider /devagent:park."
      return 0
    fi

    # #782: the MR's CI status. Window: ship is [x] in the active block, the current
    # step is past ship's row, and an mr_url is recorded. One bounded read per
    # invocation (ci_done), printed before any PHASE BREAK. Report mode (default)
    # never marks, halts or changes the exit status; `ci_gate = "block"` marks a red
    # step [!] and holds a pending/unknown one (exit 0, no dispatch). On the
    # iteration that dispatches mergetoall the read is ITS (it gates on green), so
    # this one is skipped (D1). Nothing here waits for CI. mergemr (#885) reads and
    # prints CI itself and must write its own [?], so it skips this read and the
    # block gate alike (ci_now stays 0).
    local ci_now=0
    if (( ci_done == 0 )) && [[ "$name" != mergetoall && "$name" != mergemr ]]; then
      local _ship_st _ship_row _mr_url
      _ship_st="$(checklist_step_state_by_name "$checklist" ship 2>/dev/null || true)"
      if [[ "$_ship_st" == x ]]; then
        _mr_url="$(state_ctx_get "$project" mr_url "$active" 2>/dev/null || true)"
        [[ -n "$_mr_url" ]] || ci_done=1   # shipped with no MR recorded: no CI to read
        # The name boundary matches _checklist_line_re's (a hand-annotated `18. ship:` row
        # is still ship), and `|| true` keeps a no-match from exiting next under pipefail.
        _ship_row="$(grep -E "^- \[.\][[:space:]]+[0-9]+\.[[:space:]]+ship([^A-Za-z0-9_-]|$)" "$checklist" \
            | sed -E 's/^- \[.\][[:space:]]+([0-9]+)\..*/\1/' | tail -n1 || true)"
        if [[ -n "$_ship_row" && -n "$_mr_url" ]] && (( 10#$cur > 10#$_ship_row )); then
          ci_gate_resolve "$project"
          ci_done=1
          if [[ "$CI_GATE" != off ]]; then
            ci_read "$project" "$active" "$_mr_url"
            ci_report "$issue_dir"
            ci_now=1
          fi
        fi
      fi
    fi
    if (( ci_now == 1 )) && [[ "$CI_GATE" == block ]]; then
      ci_verdict
      if [[ "$CI_VERDICT" == red ]]; then
        # checklist-stuck marks the CURRENT step, which here is the one about to run.
        bash "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$issue_dir" "$CI_LINE" || true
        [[ "$(checklist_step_state "$checklist" "$cur")" == "!" ]] \
          || die "CI gate: could not mark step $cur ($name) [!] for $CI_LINE"
        continue
      elif [[ "$CI_VERDICT" == hold ]]; then
        echo "CI gate: holding step $cur ($name) until CI finishes; nothing was marked"
        echo "  Resume once CI has finished: run /clear, then /devagent:next $project$resume_flags"
        return 0
      fi
    fi

    if (( chained == 1 )) && [[ "$breaks" == *" $name "* ]]; then
      echo "PHASE BREAK before step $cur ($name): the chain stops so the next phase starts in a fresh session; state is on disk."
      echo "  Resume: run /clear, then /devagent:next $project$resume_flags"
      echo "  (or /devagent:next $project$resume_flags --no-breaks to keep going in this session)"
      return 0
    fi

    # Plan budget (draft's item 4): scope is the first of the ~9 steps that
    # re-read imPlan.md, so an oversized plan is flagged before it is paid for.
    if [[ "$name" == scope && -f "$issue_dir/imPlan.md" ]]; then
      local _plan_bytes
      _plan_bytes="$(wc -c < "$issue_dir/imPlan.md")"
      if (( _plan_bytes > 40960 )); then
        warn "imPlan.md is $(( _plan_bytes / 1024 )) KB, over draft's 40 KB Plan budget; every later step re-reads it. Cut task code bodies and restated potholes first."
      fi
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
    # #578: name the scope for EVERY dispatch, not just the skill-backed one — a
    # misresolution (stale pointer, concurrent session) is otherwise invisible
    # until a downstream prerequisite gate fires, and the script-backed steps
    # that mutate the repo hardest were the silent ones.
    local _backing
    _backing="$(step_backing "$name" "$script_path")"
    # Header, not a trailing parenthetical: it now precedes BOTH branches, so it
    # must read as a label for what follows rather than dangle above it.
    echo "dispatch: $project/$active — step $cur ($name), $_backing"
    if [[ "$_backing" == script-backed ]]; then
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
      # #782 (D1): a mergetoall that merged ([x]) passed its own CI gate, which read
      # and printed the line; an auto-skip ([-]) read nothing, so the next step reads.
      if [[ "$name" == mergetoall ]] && (( ci_done == 0 )) \
         && [[ "$(checklist_step_state_by_name "$checklist" mergetoall 2>/dev/null || true)" == x ]]; then
        ci_done=1
      fi
      # #885: mergemr read the PR (and printed its CI line), so this invocation reads
      # no more. It exits 0 on [x], [-] or [?]: [?] is a wait, so the chain stops
      # cleanly here, before the target check and the #558 advance guard (the row
      # did not move, by design). Re-running next re-dispatches it.
      if [[ "$name" == mergemr ]]; then
        ci_done=1
        if [[ "$(checklist_step_state_by_name "$checklist" mergemr 2>/dev/null || true)" == "?" ]]; then
          echo "WAITING at step $cur (mergemr): the PR is not merged yet; state is on disk. Re-check later: /devagent:next $project$resume_flags"
          return 0
        fi
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
      # Loop: re-read checklist and advance. The chain is now a continued one.
      (( chaining == 1 )) && chained=1
      continue
    else
      # Skill-backed step: hand back to the model.
      # #578: both emissions carry the RESOLVED project, on the [project]
      # positional every /devagent:* command already accepts. A command emitted
      # without its scope re-resolves GLOBAL state at fire time (pothole
      # Issue-559). CANNOT ENFORCE: nothing here can tell whether the model
      # actually invoked the token — a dropped token silently restores the old
      # behavior, and the identification line above is the only trace.
      echo "→ Run /devagent:$name $project"
      # If chaining is in effect, emit a CHAIN: marker (Plan 6 convention)
      # so the model knows to re-invoke /devagent:next after the skill
      # completes, continuing the chain until the through-target or a
      # checkpoint (stuck/blocked/permission gate). The skill itself is
      # responsible for marking the step done on success; this script's
      # next invocation re-reads the checklist and advances.
      if (( auto == 1 )) || [[ -n "$through" ]]; then
        local chain_cmd="/devagent:next $project"
        (( auto == 1 )) && chain_cmd+=" --auto"
        [[ -n "$through" ]] && chain_cmd+=" --through $through"
        (( breaks_on == 0 )) && chain_cmd+=" --no-breaks"
        echo "CHAIN: $chain_cmd --chained"
      fi
      return 0
    fi
  done
}

main "$@"
