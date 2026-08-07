#!/usr/bin/env bash
# scripts/transition-draft-start.sh — workflow step 2 (draft) hook. Fire the
# on_draft_start tracker transition at the START of the draft step, gated by
# permissions.transition_issue (#325). Before this, on_draft_start was set in
# both live configs and claimed by spec §11 but fired by NOTHING — a standing
# lie; the tracker never learned work had started.
#
# Gating mirrors sync.sh's on_merge gate (#219): the tracker learning that work
# started is an outward, autonomous mutation, so read the gate DIRECTLY and FAIL
# CLOSED (skip + warn) when off — deliberately NOT permission_gate (which
# prompts; #141 batch fail-closed pattern). A transition failure WARNS rather
# than dies: a tracker hiccup must never block drafting (§11). Under current
# configs (transition_issue = false both projects) this is a behavior no-op.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_ISSUE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/issue}"

main() {
    local project
    active_resolve_project_try "${1:-}" 2>/dev/null || true
    project="$ACTIVE_RESOLVED_PROJECT"
    [ -n "$project" ] || { echo "draft: no project resolved; skipping on_draft_start transition" >&2; return 0; }
    active_guard_scope draft

    # #416: resolve the SESSION's issue (pin > state), NOT a raw shared-slot read.
    # A DEVAGENT_ACTIVE_ISSUE-pinned session drafting while the shared slot names
    # another issue must fire the transition for the PINNED issue, not the slot's
    # (or silently skip when the slot is empty). The old "like sync.sh" analogy was
    # wrong: sync REPORTS the shared view; draft ACTS on the session's issue — the
    # step-script convention. A scan-GUESSED issue is never acted on for an outward
    # tracker mutation (#240).
    local issue_arg
    active_resolve_issue_src "$project" 2>/dev/null || true
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
    if [ -z "$issue_arg" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        echo "draft: no pinned/active issue for $project (scan matches are not acted on); skipping on_draft_start transition" >&2
        return 0
    fi

    # Gate FIRST, fail-closed (#219). Do not touch the tracker without consent.
    local allow_transition
    allow_transition="$(config_get_project_field "$project" permissions.transition_issue 2>/dev/null || echo false)"
    if [ "$allow_transition" != "true" ]; then
        echo "draft: on_draft_start transition for $project/$issue_arg skipped — permissions.transition_issue not enabled (remote tracker state left unchanged)" >&2
        return 0
    fi

    # Route to the right issue tracker based on origin (mirror of sync/ship).
    local issue_backend issue_repo issue_num
    if [[ "$issue_arg" == Issue-Fork-* ]]; then
        issue_backend="$(config_get_project_field "$project" issue_source_fork.backend 2>/dev/null || true)"
        issue_repo="$(config_get_project_field    "$project" issue_source_fork.repo    2>/dev/null || true)"
        issue_num="${issue_arg#Issue-Fork-}"
    else
        issue_backend="$(config_get_project_field "$project" issue_source.backend 2>/dev/null || true)"
        issue_repo="$(config_get_project_field    "$project" issue_source.repo    2>/dev/null || true)"
        issue_num="${issue_arg#Issue-}"
    fi

    if [ -z "$issue_backend" ] || [ -z "$issue_repo" ]; then
        echo "draft: no issue tracker configured for $issue_arg; skipping on_draft_start transition" >&2
        return 0
    fi

    local issue_sh="$DEVAGENT_ISSUE_BACKEND_DIR/$issue_backend.sh"
    [ -x "$issue_sh" ] || { echo "draft: issue backend $issue_sh not executable; skipping on_draft_start transition" >&2; return 0; }

    # Failure WARNS, never dies — a tracker hiccup must not block drafting (§11).
    if ! "$issue_sh" transition "$issue_repo" "$issue_num" on_draft_start; then
        echo "warning: on_draft_start transition failed for $project/$issue_arg — continuing per spec §11" >&2
    fi
}

main "$@"
