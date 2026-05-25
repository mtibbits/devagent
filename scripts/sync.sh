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

    # Has step 15 been marked done?
    grep -q '^- \[x\] 15. ship'   "$issue_dir/checklist.md" 2>/dev/null || return 0
    # Has on_merge already fired? (Idempotence — log entry would exist.)
    grep -q 'sync: .* merged'     "$issue_dir/checklist.md" 2>/dev/null && return 0

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
    state="$("$code_sh" mr-state "$mr_url")"
    [ "$state" = "merged" ] || return 0

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
    [ -n "$project" ] || die "sync.sh: project or --all required"
    config_is_project "$project" || die "sync.sh: unknown project '$project'"
    sync_one_project "$project"
fi
