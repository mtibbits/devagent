#!/usr/bin/env bash
# scripts/step-model.sh — CLI face of step_models_tier (#150 table, #151 consumer).
#   step-model.sh <project> <step-num> [issue-dir]
# Echoes the configured tier (exit 0) or prints nothing and exits 1 when no
# tier resolves — callers treat empty as "no override; inherit session model".
# #458 carve-out, steps 14/21 ONLY: those two are bound to dedicated agents
# (agents/redteam-reviewer.md, agents/preship-verifier.md) whose pinned model is
# the tier of LAST RESORT, so their callers map empty to "agent default applies"
# rather than "inherit the session model". Only that fallback INTERPRETATION is
# subsumed, and only in the callers — resolution below is unchanged, and marker
# (#291) > per-step > class > default still resolves identically for every step.
# An exit 1 WITH an error on stderr is a bad per-issue marker (#291) — that is
# a stop condition for dispatchers, not an inherit.
# Read-only. Used by checking-class skills (improve 3, review 13, redmr 14,
# preship 21) to resolve the subagent dispatch model override.
# issue-dir (#291): when omitted or empty, derived from state (issue_dir) so a
# per-issue .devagent-step-models marker is honored without changing the skill
# contracts — but only while active_issue is non-empty (cleanup clears
# active_issue and not issue_dir; a finished issue's marker must not leak).
# An explicit third arg bypasses state (tests/tools).
set -euo pipefail
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
project="${1:?usage: step-model.sh <project> <step-num> [issue-dir]}"
step="${2:?usage: step-model.sh <project> <step-num> [issue-dir]}"
issue_dir="${3:-}"
if [[ -z "$issue_dir" ]]; then
  if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
    # #240: pinned session — derive ITS dir, gated on the issue's TABLE
    # existing (plan v2 rule 12): after cleanup GCs the table, a leftover
    # .devagent-step-models marker must not keep steering dispatches.
    . "$DEVAGENT_ROOT/scripts/lib/active.sh"
    if state_context_has "$project" "${DEVAGENT_ACTIVE_ISSUE}" 2>/dev/null; then
      issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"
    fi
  else
    ai="$(state_get "$project" active_issue 2>/dev/null || true)"
    if [[ -n "$ai" && "$ai" != "null" ]]; then
      issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
    fi
  fi
fi
step_models_tier "$project" "$step" "$issue_dir"
