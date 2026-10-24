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
# than dies: a tracker hiccup must never block drafting (§11). This is NOT a
# behavior no-op: as of 2026-08 the operator's config carries six projects and
# two of them (koopman-gnn, factor-ai) set permissions.transition_issue = true,
# so a bare invocation that resolves one of those fires a REAL transition on a
# REAL tracker. That is why this script is PROTECTED in
# docs/resolver-scope-triage.md and calls active_guard_scope (#572).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/transition.sh"

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

    # Gate FIRST, fail-closed (#219): transition_fire checks
    # permissions.transition_issue before any tracker call, then routes, then
    # hands the backend the project resolved here as --project (#710: never an
    # ambient DEVAGENT_PROJECT). A failure WARNS with its exit code, never dies —
    # a tracker hiccup must not block drafting (§11).
    transition_fire draft "$project" "$issue_arg" on_draft_start "$issue_backend" "$issue_repo" "$issue_num"
}

main "$@"
