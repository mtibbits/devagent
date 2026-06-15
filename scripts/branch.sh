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

# Per-issue baseline override (#162). A .devagent-baseline marker in the issue
# dir (mirroring .devagent-type/.devagent-title) cuts the branch from a
# non-default base, for issues whose targets live only on an integration branch
# (e.g. a fork-only harness on dev/all-prs). It is INTENTIONAL: unlike the
# default-baseline path below it must not silently fall back to HEAD (cf. #72).
baseline_file="$issue_dir/.devagent-baseline"
baseline_override=0
if [ -r "$baseline_file" ]; then
    # Strip all whitespace: a git ref carries none, and this collapses an
    # all-whitespace marker to empty so it is rejected rather than passed on.
    override_ref="$(tr -d '[:space:]' < "$baseline_file")"
    [ -n "$override_ref" ] || die "branch.sh: $baseline_file is empty (no baseline ref)"
    # Treat strictly as a git ref: reject anything outside the ref charset so a
    # marker can never inject shell metacharacters into the git invocations.
    case "$override_ref" in
    *[!A-Za-z0-9._/-]*) die "branch.sh: invalid baseline ref '$override_ref' in $baseline_file (allowed: A-Za-z0-9 . _ / -)" ;;
    esac
    baseline="$override_ref"
    baseline_override=1
fi

cd "$source_dir"
# Fetch the remote implied by a remote/branch baseline; a harmless no-op for a
# local-branch baseline (e.g. dev/all-prs → "dev" is not a remote). Network
# failure is absorbed as "already up to date" for offline tests.
"$DEVAGENT_GIT" fetch --quiet "$(echo "$baseline" | cut -d/ -f1)" 2>/dev/null || true
# Resolve baseline ref.
if baseline_sha="$("$DEVAGENT_GIT" rev-parse --verify "$baseline" 2>/dev/null)"; then
    :
elif [ "$baseline_override" -eq 1 ]; then
    # An explicit per-issue override that does not resolve is a hard error —
    # NEVER silently fall back to HEAD or default_baseline (that is the #72
    # mis-base hazard). Fail before any branch is created.
    die "branch.sh: per-issue baseline '$baseline' does not resolve as a git ref in $source_dir; refusing to fall back"
else
    # Default-baseline path. Distinguish a genuinely-missing remote (offline /
    # no-remote fixture — fall back to HEAD, but LOUDLY) from a configured remote
    # whose ref simply did not resolve (pruned or typo'd ref). The latter is the
    # #72 mis-base hazard: a silent HEAD fallback stacks the branch on whatever is
    # checked out (often the previous issue's branch) and ship later bases the PR
    # on the wrong parent — so refuse it rather than fall back.
    base_remote="$(echo "$baseline" | cut -d/ -f1)"
    if "$DEVAGENT_GIT" remote get-url "$base_remote" >/dev/null 2>&1; then
        die "branch.sh: default_baseline '$baseline' does not resolve though remote '$base_remote' exists (pruned or typo'd ref?); refusing to fall back to HEAD — fix default_baseline or fetch the ref (#72)"
    fi
    warn "branch.sh: default_baseline '$baseline' unresolvable and remote '$base_remote' is not configured; falling back to HEAD ($("$DEVAGENT_GIT" rev-parse --short HEAD)) — the new branch will stack on the current checkout (#72)"
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
log_append "$issue_dir" branch "created $branch from $baseline$([ "$baseline_override" -eq 1 ] && printf ' (per-issue override)') ($baseline_sha)${NOTE:+ — $NOTE}"
echo "$branch"
checklist_print_next_hint "$issue_dir/checklist.md"
