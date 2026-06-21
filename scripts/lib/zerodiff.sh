#!/usr/bin/env bash
# scripts/lib/zerodiff.sh — the shared zero-diff / nothing-to-commit guard core.
#
# The workflow's commit (10), ship (15) and mergetoall (16) steps each auto-skip
# an artifact-only issue that has no commits ahead of its baseline. The decision
# carries a correctness invariant (#25/#68): a git error must NEVER collapse into
# the destructive auto-skip (which would ship an empty PR or skip a real commit).
# This single-sources the commits-ahead query and that fail-safe direction so the
# three call sites can no longer drift.
#
# Public: zero_diff_classify <git> <work_dir> <ref> <baseline_sha>
#   Echoes exactly one of:
#     commits        rev-list succeeded and found commit(s) ahead of baseline
#     empty          rev-list succeeded and found NONE  (the only skip-authorizing
#                    verdict — an artifact-only issue)
#     indeterminate  baseline_sha is empty, OR rev-list FAILED (bad ref, not a
#                    repo, etc.) — fail-safe: no caller may treat this as skippable
#   Always returns 0; callers branch on the echoed token, so command substitution
#   never trips the caller's `set -e`.
#
# Callers map the verdict to their own skip side-effects (checklist_mark/log/exit)
# and may layer additional checks (e.g. commit.sh's staged/dirty working-tree
# distinctions) at the call site.

zero_diff_classify() {
    local git="$1" work_dir="$2" ref="$3" baseline="$4"
    # No baseline recorded (branch step not run / cleared state): cannot prove a
    # zero diff → indeterminate, never skip.
    [ -n "$baseline" ] || { echo indeterminate; return 0; }
    local out ok=1
    out="$("$git" -C "$work_dir" rev-list "$ref" "^$baseline" 2>/dev/null)" || ok=0
    # rev-list faulted (bad ref, not a repo, exit >=1): fail-safe to indeterminate.
    [ "$ok" = 1 ] || { echo indeterminate; return 0; }
    if [ -n "$out" ]; then echo commits; else echo empty; fi
    return 0
}
