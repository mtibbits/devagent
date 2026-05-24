#!/usr/bin/env bash
# scripts/mergetoall.sh — step 16. Squash-merge active branch into the
# all_prs_branch. Honors permissions.merge_mr.
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
[ -n "$project" ] || die "mergetoall.sh: project required"
config_is_project "$project" || die "mergetoall.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "mergetoall.sh: issue_dir not set or missing"

branch="$(state_get "$project" branch 2>/dev/null || true)"
[ -n "$branch" ] || die "mergetoall.sh: no branch in state"

all_prs="$(config_get_project_field "$project" all_prs_branch)"
[ -n "$all_prs" ] || die "mergetoall.sh: all_prs_branch not configured"

source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "mergetoall.sh: source_dir missing: $source_dir"

plan="$(cat <<EOF
mergetoall plan
  squash-merge $branch into $all_prs
  in           $source_dir
EOF
)"
permission_gate "$project" merge_mr "$plan"

cd "$source_dir"
"$DEVAGENT_GIT" checkout "$all_prs"
"$DEVAGENT_GIT" merge --squash "$branch"
# Use the tip commit's subject so the squash commit is identifiable in log --oneline.
# Falls back to a generic message if the branch tip has no subject.
subject="$("$DEVAGENT_GIT" log -1 --pretty=%s "$branch")"
subject="${subject:-"merge $branch into $all_prs"}"
"$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
    commit -m "$subject"

state_set "$project" last_step      "16"
state_set "$project" last_step_name "mergetoall"
checklist_mark "$issue_dir/checklist.md" 16 x
log_append "$issue_dir" mergetoall "squashed $branch → $all_prs${NOTE:+ — $NOTE}"
checklist_print_next_hint "$issue_dir/checklist.md"
