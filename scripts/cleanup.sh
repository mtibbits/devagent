#!/usr/bin/env bash
# scripts/cleanup.sh — step 20. Switch source tree back to default_baseline,
# commit/push devdoc if permissions.commit_devdoc=true, clear active_issue.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "cleanup.sh: project required"
config_is_project "$project" || die "cleanup.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "cleanup.sh: issue_dir not set or missing"

source_dir="$(config_get_project_field "$project" source_dir)"
devdoc_dir="$(config_get_project_field "$project" devdoc_dir)"
baseline="$(config_get_project_field "$project" default_baseline)"
base_branch="${baseline##*/}"

# Restore source tree to base branch.
( cd "$source_dir" && "$DEVAGENT_GIT" checkout "$base_branch" )

# Bookkeeping first — updates checklist.md so devdoc has something to commit.
state_set "$project" last_step      "20"
state_set "$project" last_step_name "cleanup"
state_set "$project" active_issue   ""
state_set "$project" branch         ""
state_set "$project" worktree_path  ""

checklist_mark "$issue_dir/checklist.md" 20 x
log_append "$issue_dir" cleanup "tree restored, active_issue cleared${NOTE:+ — $NOTE}"

# Reconcile the WBS against the now-completed checklist so the leaf for
# this issue flips to [x]. --if-exists silently no-ops if the project
# has no WBS.md (it's an optional artifact). We pass project explicitly
# because active_issue was just cleared above.
"$DEVAGENT_ROOT/scripts/wbs-update.sh" --if-exists "$project" || \
    warn "cleanup: wbs reconcile failed (non-fatal)"

# Commit + push devdoc if permitted.
commit_devdoc="$(config_get_project_field "$project" "permissions.commit_devdoc" 2>/dev/null || echo false)"
if [ "$commit_devdoc" = "true" ]; then
    plan="cleanup plan: commit + push devdoc updates for $issue_arg"
    permission_gate "$project" commit_devdoc "$plan"
    cd "$devdoc_dir"
    if ! "$DEVAGENT_GIT" diff --quiet || ! "$DEVAGENT_GIT" diff --cached --quiet; then
        "$DEVAGENT_GIT" add -A
        "$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
            commit -m "devdoc: $issue_arg cleanup"
        if "$DEVAGENT_GIT" remote get-url origin >/dev/null 2>&1; then
            "$DEVAGENT_GIT" push origin HEAD 2>/dev/null || \
                echo "warning: devdoc push failed; commit retained locally" >&2
        fi
    fi
fi
