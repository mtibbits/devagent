#!/usr/bin/env bash
# scripts/branch.sh — workflow step 6. Compute prefix from branch_prefix_map,
# baseline on default_baseline, optionally create a git worktree.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/checklist.sh
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
# shellcheck source=lib/log.sh
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "branch.sh: project required"
config_is_project "$project" || die "branch.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
[ -n "$issue_arg" ] || die "branch.sh: no active issue and no issue arg"

# Extract numeric portion: Issue-676 → 676 ; Issue-Fork-42 → 42
issue_num="${issue_arg#Issue-}"
issue_num="${issue_num#Fork-}"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "branch.sh: issue dir not found: $issue_dir"

# Read issue type and title from marker files (written by /devagent:draft, step 1).
type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
[ -r "$type_file" ]  || die "branch.sh: missing $type_file (issue type not classified)"
[ -r "$title_file" ] || die "branch.sh: missing $title_file (issue title not captured)"
issue_type="$(tr -d '\n' < "$type_file")"
title="$(tr -d '\n' < "$title_file")"

# Slugify: lowercase, non-alnum → '-', collapse, trim, cap 40 chars.
slug="$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c1-40 \
    | sed 's/-$//')"

# Prefix lookup via direct dotted-key walk into the inline branch_prefix_map table.
prefix="$(config_get_project_field "$project" "branch_prefix_map.$issue_type" 2>/dev/null || true)"
[ -n "$prefix" ] || die "branch.sh: no prefix mapped for type '$issue_type'"

branch="$prefix/$issue_num-$slug"
baseline="$(config_get_project_field "$project" default_baseline)"
source_dir="$(config_get_project_field "$project" source_dir)"

cd "$source_dir"
# Fetch baseline; absorb network failure as "already up to date" for offline tests.
"$DEVAGENT_GIT" fetch --quiet "$(echo "$baseline" | cut -d/ -f1)" 2>/dev/null || true
# Resolve baseline ref; fall back to HEAD for offline/no-remote fixtures.
if baseline_sha="$("$DEVAGENT_GIT" rev-parse --verify "$baseline" 2>/dev/null)"; then
    :
else
    baseline_sha="$("$DEVAGENT_GIT" rev-parse HEAD)"
fi

worktree_dir=""
use_worktree="$(config_get_project_field "$project" use_worktree 2>/dev/null || echo false)"
if [ "$use_worktree" = "true" ]; then
    worktree_root="$(config_get_project_field "$project" worktree_root 2>/dev/null || echo "$source_dir-wt")"
    worktree_dir="$worktree_root/issue-$issue_num"
    "$DEVAGENT_GIT" worktree add -b "$branch" "$worktree_dir" "$baseline_sha"
else
    "$DEVAGENT_GIT" checkout -b "$branch" "$baseline_sha"
fi

state_set "$project" branch        "$branch"
state_set "$project" baseline_sha  "$baseline_sha"
state_set "$project" worktree_path "$worktree_dir"
state_set "$project" last_step      "6"
state_set "$project" last_step_name "branch"

checklist_mark "$issue_dir/checklist.md" 6 x
log_append "$issue_dir" branch "created $branch from $baseline ($baseline_sha)${NOTE:+ — $NOTE}"
echo "$branch"
checklist_print_next_hint "$issue_dir/checklist.md"
