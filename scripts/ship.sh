#!/usr/bin/env bash
# scripts/ship.sh — workflow step 15. Push branch, create MR, fire on_ship.
# Honors permissions.push_mr and ship_as_draft. If fork_first=true, files MR
# on the fork before referencing upstream.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"
. "$DEVAGENT_ROOT/scripts/lib/depends.sh"

: "${DEVAGENT_GIT:=git}"
: "${DEVAGENT_CODE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/code}"
: "${DEVAGENT_ISSUE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/issue}"

# Strip --strict-deps from anywhere in argv before positional parsing.
strict_deps=0
filtered=()
for arg in "$@"; do
    case "$arg" in
        --strict-deps) strict_deps=1 ;;
        *) filtered+=("$arg") ;;
    esac
done
set -- "${filtered[@]+"${filtered[@]}"}"

project="${1:-}"
[ -n "$project" ] || die "ship.sh: project required"
config_is_project "$project" || die "ship.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
[ -n "$issue_arg" ] || die "ship.sh: no active issue and no issue arg"

# Phase 9 dependency pre-flight (warn unless --strict-deps was passed).
export DEVAGENT_STATE_DIR="$(devagent_home)/state"
if ! depends_ship_preflight "$project" "$issue_arg" "$strict_deps"; then
    exit 2
fi

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "ship.sh: issue_dir not set or missing"

branch="$(state_get "$project" branch 2>/dev/null || true)"
[ -n "$branch" ] || die "ship.sh: no branch in state (run /devagent:branch first)"

# Zero-diff guard: artifact-only issues have no commits to push/PR.
baseline_sha="$(state_get "$project" baseline_sha 2>/dev/null || true)"
source_dir="$(config_get_project_field "$project" source_dir)"
if [ -n "$baseline_sha" ] && [ -z "$("$DEVAGENT_GIT" -C "$source_dir" rev-list HEAD "^$baseline_sha" 2>/dev/null)" ]; then
    info "ship.sh: no commits on branch — auto-marking step 15 [-] (zero-diff issue)"
    checklist_mark "$issue_dir/checklist.md" 15 -
    log_append "$issue_dir" ship "auto-skipped: zero commits on branch (artifact-only issue)"
    exit 0
fi

code_backend="$(config_get_project_field "$project" code_source.backend)"
upstream_repo="$(config_get_project_field "$project" code_source.upstream)"
fork_repo="$(config_get_project_field "$project" code_source.fork 2>/dev/null || true)"
fork_first="$(config_get_project_field "$project" fork_first 2>/dev/null || echo false)"
fork_only="$(config_get_project_field "$project" fork_only 2>/dev/null || echo false)"

# fork_only implies fork_first; validate the fork is configured.
if [ "$fork_only" = "true" ]; then
    [ -n "$fork_repo" ] || die "ship.sh: fork_only=true requires code_source.fork to be set"
    fork_first=true
fi
ship_as_draft_global="$(config_get_default ship_as_draft 2>/dev/null || echo false)"
ship_as_draft_proj="$(config_get_project_field "$project" ship_as_draft 2>/dev/null || echo "$ship_as_draft_global")"
# Per-issue draft override: .devagent-draft forces draft state.
[ -r "$issue_dir/.devagent-draft" ] && ship_as_draft_proj="true"

push_remote="$(config_get_project_field "$project" source_remote 2>/dev/null || echo origin)"

# Route to the right issue tracker based on the issue's origin:
#   Issue-Fork-NNN -> issue_source_fork (the fork's tracker)
#   Issue-NNN      -> issue_source       (the upstream tracker)
if [[ "$issue_arg" == Issue-Fork-* ]]; then
    issue_backend="$(config_get_project_field "$project" issue_source_fork.backend 2>/dev/null || true)"
    issue_repo="$(config_get_project_field    "$project" issue_source_fork.repo    2>/dev/null || true)"
    issue_num="${issue_arg#Issue-Fork-}"
else
    issue_backend="$(config_get_project_field "$project" issue_source.backend)"
    issue_repo="$(config_get_project_field    "$project" issue_source.repo)"
    issue_num="${issue_arg#Issue-}"
fi

mr_body="$issue_dir/mr.md"
[ -r "$mr_body" ] || die "ship.sh: missing $mr_body (run /devagent:draftmr first)"

# Permission gate.
target_repo_for_plan="$upstream_repo"
if [ "$fork_only" = "true" ]; then
    target_repo_for_plan="$fork_repo (fork only — upstream not targeted)"
elif [ "$fork_first" = "true" ] && [ -n "$fork_repo" ]; then
    target_repo_for_plan="$fork_repo (fork)"
fi
plan="$(cat <<EOF
ship plan
  branch:     $branch
  push to:    $push_remote
  MR repo:    $target_repo_for_plan
  draft?:     $ship_as_draft_proj
  issue:      $issue_arg → on_ship
EOF
)"
permission_gate "$project" push_mr "$plan"

code_sh="$DEVAGENT_CODE_BACKEND_DIR/$code_backend.sh"
[ -x "$code_sh" ] || die "ship.sh: missing code backend $code_sh"

# Push branch.
source_dir="$(config_get_project_field "$project" source_dir)"
( cd "$source_dir" && "$code_sh" push-branch "$push_remote" "$branch" )

# Resolve target repo. fork_only or fork_first → fork; else upstream.
target_repo="$upstream_repo"
if [ "$fork_first" = "true" ] && [ -n "$fork_repo" ]; then
    target_repo="$fork_repo"
fi

base_branch="$(config_get_project_field "$project" default_baseline | sed 's|^[^/]*/||')"
[ -n "$base_branch" ] || base_branch="main"

title_file="$issue_dir/.devagent-title"
[ -r "$title_file" ] || die "ship.sh: missing $title_file (run /devagent:branch first)"
title="$(tr -d '\n' < "$title_file")"

draft_flag=()
[ "$ship_as_draft_proj" = "true" ] && draft_flag=(--draft)

mr_url="$("$code_sh" create-mr "$target_repo" "$title" "$mr_body" "$branch" "$base_branch" "${draft_flag[@]}")"
[ -n "$mr_url" ] || die "ship.sh: create-mr returned empty URL"

# Fire on_ship transition. Tolerate missing transition verb / failures per §11.
# Skipped under fork_only. Also skipped if the routed backend/repo isn't
# configured (e.g. Issue-Fork-* with no [issue_source_fork] block).
issue_sh="$DEVAGENT_ISSUE_BACKEND_DIR/${issue_backend:-}.sh"
if [ "$fork_only" = "true" ]; then
    echo "fork-only mode: skipping on_ship transition" >&2
elif [ -z "$issue_backend" ] || [ -z "$issue_repo" ]; then
    echo "ship.sh: no issue tracker configured for $issue_arg; skipping transition" >&2
elif [ -x "$issue_sh" ]; then
    if ! "$issue_sh" transition "$issue_repo" "$issue_num" on_ship; then
        echo "warning: issue transition failed — continuing per spec §11" >&2
    fi
fi

state_set "$project" mr_url         "$mr_url"
state_set "$project" last_step      "15"
state_set "$project" last_step_name "ship"
checklist_mark "$issue_dir/checklist.md" 15 x
log_append "$issue_dir" ship "MR $mr_url${NOTE:+ — $NOTE}"
echo "$mr_url"
checklist_print_next_hint "$issue_dir/checklist.md"
