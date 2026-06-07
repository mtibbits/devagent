#!/usr/bin/env bash
# scripts/mergetoall.sh — step 16. Squash-merge active branch into the
# all_prs_branch. Always local; remote push is opt-in via
# all_prs_auto_push=true (per-project config). NO GitHub PR closure
# either way. Honors permissions.merge_to_all_prs (fall back to legacy
# permissions.merge_mr name for one-version backward compat).
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

# Zero-diff guard: artifact-only issues have nothing to squash-merge.
baseline_sha="$(state_get "$project" baseline_sha 2>/dev/null || true)"
source_dir="$(config_get_project_field "$project" source_dir)"
if [ -n "$baseline_sha" ] && [ -z "$("$DEVAGENT_GIT" -C "$source_dir" rev-list HEAD "^$baseline_sha" 2>/dev/null)" ]; then
    info "mergetoall.sh: no commits on branch — auto-marking step 16 [-] (zero-diff issue)"
    checklist_mark "$issue_dir/checklist.md" 16 -
    log_append "$issue_dir" mergetoall "auto-skipped: zero commits on branch (artifact-only issue)"
    exit 0
fi

all_prs="$(config_get_project_field "$project" all_prs_branch 2>/dev/null || true)"
if [ -z "$all_prs" ]; then
    info "mergetoall.sh: all_prs_branch not configured — auto-marking step 16 [-]"
    checklist_mark "$issue_dir/checklist.md" 16 -
    log_append "$issue_dir" mergetoall "auto-skipped: all_prs_branch not configured"
    exit 0
fi

# --- #26 Defect B: a stale all_prs base bundles the upstream delta into the
# squash commit. FF is impossible (squash-divergent), so detect and refuse. ---
. "$DEVAGENT_ROOT/scripts/lib/upstream.sh"
up_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
if [ -n "$up_ref" ]; then
    up_remote="${up_ref%%/*}"
    upstream_fetch "$source_dir" "$up_remote"
    behind="$(upstream_behind_count "$source_dir" "$all_prs" "$up_ref")"
    if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
        die "mergetoall.sh: $all_prs is $behind commits behind $up_ref — squashing now would bundle the upstream delta into the issue commit (#26). Integrate upstream first (merge $up_ref into $all_prs, or cherry-pick $branch's commit onto an up-to-date $all_prs), then re-run. Refusing to misrepresent the issue diff."
    fi
fi

# Auto-push the all_prs branch to the remote after the local merge.
# Defaults: auto_push=false; remote=source_remote (which itself defaults
# to "origin"). Push is per-issue convenience — failure is non-fatal,
# the local commit is preserved.
all_prs_auto_push="$(config_get_project_field "$project" all_prs_auto_push 2>/dev/null || echo false)"
all_prs_remote="$(config_get_project_field "$project" all_prs_remote 2>/dev/null || true)"
[ -n "$all_prs_remote" ] || all_prs_remote="$(config_get_project_field "$project" source_remote 2>/dev/null || echo origin)"

source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "mergetoall.sh: source_dir missing: $source_dir"

push_line=""
if [ "$all_prs_auto_push" = "true" ]; then
    push_line="
  push to:     $all_prs_remote/$all_prs (after local merge)"
fi
plan="$(cat <<EOF
mergetoall plan
  squash-merge $branch into $all_prs
  in           $source_dir${push_line}
EOF
)"
# Resolve permission gate name with one-version backward compat.
gate_name="merge_to_all_prs"
if [ -z "$(config_get_project_field "$project" "permissions.merge_to_all_prs" 2>/dev/null || true)" ] \
   && [ -n "$(config_get_project_field "$project" "permissions.merge_mr" 2>/dev/null || true)" ]; then
    gate_name="merge_mr"
fi
permission_gate "$project" "$gate_name" "$plan"

cd "$source_dir"

# Restore target if a genuine conflict forces us to bail — never leave the
# operator on a half-applied all_prs (that silently breaks --auto, #33).
# Detached HEAD → empty → not restored, but all_prs is still left clean.
orig_branch="$("$DEVAGENT_GIT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# Apply ONLY the issue branch's own delta (baseline_sha..branch) using baseline_sha
# as the 3-way base — NOT git's merge-base, which collapses to the default base for
# a child stacked on a squash-merged parent and re-derives the parent delta as
# spurious conflicts (#33). cherry-pick bases on a commit's PARENT, so a synthetic
# commit (branch's tree, parent = baseline_sha) makes baseline_sha the base
# directly. Non-stacked: baseline_sha == git merge-base, so the staged tree and the
# resulting squash commit are byte-identical to the old `git merge --squash`.
base="$baseline_sha"
[ -n "$base" ] || base="$("$DEVAGENT_GIT" merge-base "$all_prs" "$branch")"
squash_commit="$(GIT_AUTHOR_NAME=devagent GIT_AUTHOR_EMAIL=devagent@local \
    GIT_COMMITTER_NAME=devagent GIT_COMMITTER_EMAIL=devagent@local \
    "$DEVAGENT_GIT" commit-tree "$branch^{tree}" -p "$base" -m squash)"

"$DEVAGENT_GIT" checkout "$all_prs"
if ! "$DEVAGENT_GIT" cherry-pick --no-commit "$squash_commit"; then
    # Genuine overlap with already-integrated work. cherry-pick --no-commit sets no
    # CHERRY_PICK_HEAD, so `--abort` would fail; reset --hard discards the conflicted
    # index+worktree back to a clean all_prs. Restore the starting branch, then fail.
    "$DEVAGENT_GIT" reset --hard --quiet
    [ -n "$orig_branch" ] && "$DEVAGENT_GIT" checkout --quiet "$orig_branch"
    die "mergetoall.sh: $branch's own delta conflicts with work already integrated into $all_prs (a genuine overlap, not the #33 stacked-parent artifact). Reconcile by merging/rebasing $all_prs into $branch (or applying the overlapping hunk by hand), then re-run. Refusing to leave a half-applied index."
fi

# Use the tip commit's subject so the squash commit is identifiable in log --oneline.
# Falls back to a generic message if the branch tip has no subject.
subject="$("$DEVAGENT_GIT" log -1 --pretty=%s "$branch")"
subject="${subject:-"merge $branch into $all_prs"}"
"$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
    commit -m "$subject"

# Opt-in auto-push of the all_prs branch. Non-fatal on failure: the
# local commit is the load-bearing artifact; remote sync is convenience.
push_status="local-only"
if [ "$all_prs_auto_push" = "true" ]; then
    if "$DEVAGENT_GIT" push "$all_prs_remote" "$all_prs"; then
        push_status="pushed to $all_prs_remote/$all_prs"
    else
        echo "warning: push of $all_prs to $all_prs_remote failed; commit retained locally" >&2
        push_status="push failed (local commit retained)"
    fi
fi

state_set "$project" last_step      "16"
state_set "$project" last_step_name "mergetoall"
checklist_mark "$issue_dir/checklist.md" 16 x
log_append "$issue_dir" mergetoall "squashed $branch → $all_prs; $push_status${NOTE:+ — $NOTE}"
checklist_print_next_hint "$issue_dir/checklist.md"
