#!/usr/bin/env bash
# scripts/sync.sh — async merge detection. For each shipped issue (step 15
# done, mr_url set), call code/<backend>.sh mr-state and if "merged", fire
# the on_merge transition exactly once (idempotent — relies on the log
# entry to skip already-handled issues).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_CODE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/code}"
: "${DEVAGENT_ISSUE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/issue}"

# #363: the checklist IS the closeout queue. Sync executes NO closeout steps —
# on a merge it just makes the checklist truthful (unblock) and reminds the
# operator (nudge). Both are local, gate-free, prompt-free (safe in a cron --all).
_SYNC_CLOSEOUT_STEPS="mergetoall updatewbs impact lessonslearned cleanup"

# Flip any closeout step stuck at [?] (the impact "not merged" halt) → [ ], so
# post-merge /devagent:next proceeds instead of "blocked-external, consider park".
# Only [?] (never [x]/[-]/[!]/[P]); revision-scoped; ≥1 flip → one log line.
_sync_closeout_unblock() {
    local issue_dir="$1" name flips=0 g
    for name in $_SYNC_CLOSEOUT_STEPS; do
        g="$(checklist_step_state_by_name "$issue_dir/checklist.md" "$name" 2>/dev/null || true)"
        if [ "$g" = "?" ]; then
            checklist_mark_by_name "$issue_dir/checklist.md" "$name" " "
            flips=$((flips + 1))
        fi
    done
    [ "$flips" -gt 0 ] && log_append "$issue_dir" sync "unblocked $flips closeout step(s) after merge ([?]->[ ])"
    return 0
}

# Print the derived CLOSEOUT nudge while any closeout step is non-terminal.
# Derived from checklist state (not stored) → re-prints every sync until cleanup
# lands, silences itself after. No network, no prompt.
_sync_closeout_nudge() {
    local project="$1" issue_dir="$2" issue_arg="$3" pending
    [ -n "$issue_arg" ] || return 0
    # shellcheck disable=SC2086
    pending="$(checklist_nonterminal_by_names "$issue_dir/checklist.md" $_SYNC_CLOSEOUT_STEPS \
                | sed 's/:.*//' | paste -sd, - )"
    [ -n "$pending" ] || return 0
    echo "CLOSEOUT: $project/$issue_arg merged — pending: $pending — run /devagent:next $project --auto"
}

# #240: sync iterates PROJECTS and reports the SHARED view by definition —
# raw state_get reads are deliberate here (a session pin must not leak into
# every project's iteration).
sync_one_project() {
    local project="$1"
    local state_file
    state_file="$(state_path "$project")"
    [ -r "$state_file" ] || return 0

    local issue_dir mr_url
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
    mr_url="$(state_get   "$project" mr_url    2>/dev/null || true)"
    [ -n "$issue_dir" ] && [ -d "$issue_dir" ] || return 0
    [ -n "$mr_url" ] || return 0

    # Has the ACTIVE revision's ship step been marked done? (#318) — a file-wide
    # grep matched revision 1's [x] 15 after a revise and fired on a revision that
    # had not re-shipped; checklist_step_state_by_name scopes to the active
    # revision block (#76), file-wide only when there are no revision headings.
    [ "$(checklist_step_state_by_name "$issue_dir/checklist.md" ship 2>/dev/null || true)" = "x" ] || return 0
    # Has on_merge already fired FOR THIS REVISION? (#318) — the idempotence marker
    # is a `## Log` entry and revise.sh appends `## Revision N` AFTER `## Log`
    # (log.sh #75), so the marker sits BEFORE the active revision block: a file-wide
    # grep matched revision 1's stale marker (suppressing a re-shipped revision-2
    # merge forever), and scoping to the active block would exclude the log and
    # re-fire every run. Correct scope = the log's own revision boundary: a merge
    # marker counts only at/after the last `revise:` entry.
    if awk '
        /^## Log/            { inlog=1; next }
        /^## /               { inlog=0 }
        !inlog               { next }
        /  revise: /         { fired=0; next }
        /  sync: .* merged/  { fired=1 }
        END                  { exit (fired ? 0 : 1) }
      ' "$issue_dir/checklist.md" 2>/dev/null; then
        # #363: on_merge already fired for this revision — re-print the closeout
        # nudge (derived, ZERO network: this sits before the mr-state call) while
        # closeout is still pending; silent once cleanup lands.
        _sync_closeout_nudge "$project" "$issue_dir" \
            "$(state_get "$project" active_issue 2>/dev/null || true)"
        return 0
    fi

    local code_backend issue_backend issue_repo issue_arg issue_num
    code_backend="$(config_get_project_field  "$project" code_source.backend)"
    issue_arg="$(state_get                    "$project" active_issue 2>/dev/null || true)"
    # cleanup.sh clears active_issue but leaves issue_dir/mr_url for a session
    # — without this guard, sync would fire on_merge with an empty issue number.
    [ -n "$issue_arg" ] || return 0

    # Route to the right issue tracker based on origin (mirror of ship.sh).
    if [[ "$issue_arg" == Issue-Fork-* ]]; then
        issue_backend="$(config_get_project_field "$project" issue_source_fork.backend 2>/dev/null || true)"
        issue_repo="$(config_get_project_field    "$project" issue_source_fork.repo    2>/dev/null || true)"
        issue_num="${issue_arg#Issue-Fork-}"
    else
        issue_backend="$(config_get_project_field "$project" issue_source.backend 2>/dev/null || true)"
        issue_repo="$(config_get_project_field    "$project" issue_source.repo    2>/dev/null || true)"
        issue_num="${issue_arg#Issue-}"
    fi

    local code_sh issue_sh state
    code_sh="$DEVAGENT_CODE_BACKEND_DIR/$code_backend.sh"
    issue_sh="$DEVAGENT_ISSUE_BACKEND_DIR/${issue_backend:-}.sh"
    [ -x "$code_sh" ] || return 0
    # #141: guard the network call so a per-project mr-state failure (auth/network)
    # warns and skips instead of aborting the whole --all loop under set -e.
    if ! state="$("$code_sh" mr-state "$mr_url")"; then
        echo "warning: mr-state failed for $project/$issue_arg; skipping" >&2
        return 0
    fi
    [ "${state,,}" = "merged" ] || return 0   # #43: gh returns "MERGED" (uppercase)

    # #363: the merge is a local fact — unblock the closeout queue and nudge
    # BEFORE the #219 remote-transition gate (which returns early when
    # transition_issue is off). So an operator with the gate off still gets an
    # unblocked, truthful checklist + the nudge; #219's no-marker-when-gated
    # behavior below is untouched.
    _sync_closeout_unblock "$issue_dir"
    _sync_closeout_nudge "$project" "$issue_dir" "$issue_arg"

    # #219: gate the remote on_merge transition. This is an outward, autonomous
    # mutation of tracker state — sync runs --all batch/non-interactive and must
    # continue-on-failure (#141), so read the gate directly and FAIL CLOSED
    # (skip + warn) rather than calling permission_gate (which would prompt or
    # die and abort the loop). Deliberately do NOT write the "merged" idempotence
    # marker when gated off, so enabling transition_issue later still fires.
    # (ship's on_ship is NOT gated here — it is already behind ship's push_mr
    # gate + an explicit interactive ship; see ship.sh.)
    local allow_transition
    allow_transition="$(config_get_project_field "$project" permissions.transition_issue 2>/dev/null || echo false)"
    if [ "$allow_transition" != "true" ]; then
        echo "sync: on_merge transition for $project/$issue_arg skipped — permissions.transition_issue not enabled (remote tracker state left unchanged)" >&2
        return 0
    fi

    if [ -z "$issue_backend" ] || [ -z "$issue_repo" ]; then
        echo "sync: no issue tracker configured for $issue_arg; skipping on_merge transition" >&2
    elif [ -x "$issue_sh" ]; then
        if ! "$issue_sh" transition "$issue_repo" "$issue_num" on_merge; then
            echo "warning: on_merge transition failed for $project/$issue_arg" >&2
        fi
    fi
    log_append "$issue_dir" sync "$issue_arg merged → on_merge fired"
}

if [ "${1:-}" = "--all" ]; then
    while read -r p; do
        [ -n "$p" ] && sync_one_project "$p"
    done < <(config_list_projects)
else
    project="${1:-}"
    [ -n "$project" ] || die "project or --all required"
    config_is_project "$project" || die "unknown project '$project'"
    sync_one_project "$project"
fi
