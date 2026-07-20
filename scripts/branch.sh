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
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=lib/checklist.sh
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
# shellcheck source=lib/log.sh
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
# shellcheck source=lib/conn-diag.sh
. "$DEVAGENT_ROOT/scripts/lib/conn-diag.sh"
# shellcheck source=lib/baseline.sh
. "$DEVAGENT_ROOT/scripts/lib/baseline.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue (the scan tier
    # can adopt a parked issue's checklist) — pin/state only, else die.
    # (stderr NOT suppressed: an invalid pin must die loudly here, F6.)
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi
[ -n "$issue_arg" ] || die "no active issue and no issue arg"

# Extract numeric portion: Issue-676 → 676 ; Issue-Fork-42 → 42
issue_num="${issue_arg#Issue-}"
issue_num="${issue_num#Fork-}"

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue dir not found: $issue_dir"

# Read issue type and title from marker files (written by /devagent:draft, step 1).
type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
[ -r "$type_file" ]  || die "missing $type_file (issue type not classified)"
[ -r "$title_file" ] || die "missing $title_file (issue title not captured)"
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
[ -n "$prefix" ] || die "no prefix mapped for type '$issue_type'"

# #422: build the branch's issue component from the FULL arg (minus "Issue-",
# lowercased) so Issue-42 → 42 and Issue-Fork-42 → fork-42 get DISTINCT branch
# names. The bare $issue_num strips "Fork-" too and collapsed the twins onto one
# branch → `git worktree add -b` / `checkout -b` died "already exists". #332 fixed
# only the worktree leaf, not the branch name. Non-fork is unchanged (Issue-42 → 42).
branch_issue="$(printf '%s' "${issue_arg#Issue-}" | tr '[:upper:]' '[:lower:]')"
branch="$prefix/$branch_issue-$slug"
# #536: baseline resolution now lives in scripts/lib/baseline.sh (shared with
# spike.sh). Setter-globals, not `$(...)`: the resolver dies/warns and returns four
# values. Assign back into the historical lowercase names so every downstream
# reference below is untouched (behavior-preserving extraction).
baseline_resolve "$project" "$issue_dir"
baseline="$BASELINE_REF"
baseline_sha="$BASELINE_SHA"
baseline_override="$BASELINE_OVERRIDE"
source_dir="$BASELINE_SOURCE_DIR"

worktree_dir=""
use_worktree="$(config_get_project_field "$project" use_worktree 2>/dev/null || echo false)"
if [ "$use_worktree" = "true" ]; then
    worktree_root="$(config_get_project_field "$project" worktree_root 2>/dev/null || echo "$source_dir-wt")"
    # #332: leaf from the FULL issue arg (lowercased) so Issue-42 and
    # Issue-Fork-42 get distinct worktrees (issue-42 vs issue-fork-42). The bare
    # $issue_num strips "Fork-" and collapsed the twins onto one dir → the fork
    # twin's `git worktree add` failed "already exists". Non-fork leaf is
    # unchanged (Issue-42 → issue-42), so existing worktrees/state are intact.
    worktree_dir="$worktree_root/$(printf '%s' "$issue_arg" | tr '[:upper:]' '[:lower:]')"
    "$DEVAGENT_GIT" worktree add -b "$branch" "$worktree_dir" "$baseline_sha"
else
    "$DEVAGENT_GIT" checkout -b "$branch" "$baseline_sha"
fi

# #96: one atomic transaction — a concurrent session can no longer observe
# branch from this issue paired with baseline_sha from another.
state_ctx_set_many "$project" "$issue_arg" \
  str branch         "$branch" \
  str baseline_sha   "$baseline_sha" \
  str worktree_path  "$worktree_dir" \
  str last_step      "6" \
  str last_step_name "branch"

checklist_mark "$issue_dir/checklist.md" 6 x
log_append "$issue_dir" branch "created $branch from $baseline$([ "$baseline_override" -eq 1 ] && printf ' (per-issue override)') ($baseline_sha)${NOTE:+ — $NOTE}"
echo "$branch"
checklist_print_next_hint "$issue_dir/checklist.md"
