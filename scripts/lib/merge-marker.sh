#!/usr/bin/env bash
# scripts/lib/merge-marker.sh — the on_merge idempotence marker (#885 A0.1).
# Source-only. Requires paths.sh, io.sh, config.sh, log.sh and transition.sh
# sourced first.
#
# One implementation for the two callers that detect a merge and fire on_merge:
# sync.sh (async, cron --all) and mergemr.sh (the merge step). The marker is a
# `## Log` line that is ALWAYS written under the `sync` tag, whichever caller
# fired, so either caller's next run sees it and neither fires twice. It is
# written only when nothing is left to retry (#710; pre-#710
# `merged → on_merge fired` lines still match, and nothing is backfilled):
#   landed      <issue> merged → on_merge landed: "<state>" on <repo>
#               (… landed on <repo>: a custom backend that maps for itself)
#   no-tracker  <issue> merged → on_merge skipped: no issue tracker configured
#   fork-only   <issue> merged → on_merge skipped: fork_only (upstream tracker not targeted)
# gated, unmapped, no-backend and failed write NO marker, so the next run
# retries: enabling the gate, adding the mapping or a recovered tracker still
# fires. A failure prints one warning (with the caller's retry note) and no log
# line — a second spelling that must never match the marker would be a fragile
# machine-read field, repeated on every cron --all (register 586).

# merge_marker_present <checklist>: 0 when on_merge already fired FOR THIS
# REVISION (#318). The marker is a `## Log` entry and revise.sh appends
# `## Revision N` AFTER `## Log` (log.sh #75), so the marker sits BEFORE the
# active revision block: a file-wide grep matched revision 1's stale marker
# (suppressing a re-shipped revision-2 merge forever), and scoping to the
# active block would exclude the log and re-fire every run. Correct scope = the
# log's own revision boundary: a merge marker counts only at/after the last
# `revise:` entry. 1 otherwise, also for an unreadable checklist.
merge_marker_present() {
    awk '
        /^## Log/            { inlog=1; next }
        /^## /               { inlog=0 }
        !inlog               { next }
        /  revise: /         { fired=0; next }
        /  sync: .* merged/  { fired=1 }
        END                  { exit (fired ? 0 : 1) }
      ' "$1" 2>/dev/null
}

# merge_marker_fire <caller> <project> <issue> <issue_dir> <suffix>: route the
# issue to its tracker by origin (transition_route), fire on_merge through the
# gate (transition_fire, which reads the gate directly and FAILS CLOSED — skip
# and warn — never prompting), and write the marker for the outcomes that leave
# nothing to retry. <caller> prefixes transition_fire's stderr lines; <suffix>
# is its retry note on a failed or no-backend outcome. Call it BARE: it leaves
# transition_fire's TRANSITION_* setter-globals for the caller. Always returns 0.
merge_marker_fire() {
    local caller="$1" project="$2" issue_arg="$3" issue_dir="$4" suffix="${5:-}"
    transition_route "$project" "$issue_arg"
    local issue_backend="$TR_BACKEND" issue_repo="$TR_REPO" issue_num="$TR_NUM"
    transition_fire "$caller" "$project" "$issue_arg" on_merge "$issue_backend" "$issue_repo" "$issue_num" \
        "$suffix"
    case "$TRANSITION_OUTCOME" in
        landed)
            log_append "$issue_dir" sync "$issue_arg merged → on_merge landed${TRANSITION_TARGET:+: \"$TRANSITION_TARGET\"} on $issue_repo" ;;
        no-tracker)
            log_append "$issue_dir" sync "$issue_arg merged → on_merge skipped: no issue tracker configured" ;;
        fork-only)
            log_append "$issue_dir" sync "$issue_arg merged → on_merge skipped: fork_only (upstream tracker not targeted)" ;;
    esac
    return 0
}
