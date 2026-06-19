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
. "$DEVAGENT_ROOT/scripts/lib/coauthor.sh"
. "$DEVAGENT_ROOT/scripts/lib/stacked.sh"

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
explicit_issue="$issue_arg"   # remember the explicit arg before the fallback (#70)
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
[ -n "$issue_arg" ] || die "ship.sh: no active issue and no issue arg"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "ship.sh: issue_dir not set or missing"

# #70: an explicit issue arg must name the active issue. issue_dir/branch/baseline
# always come from state, so a mismatched arg would push the active issue's branch
# but route on_ship (and Fork/non-Fork backend) to a different issue. Die before
# the dependency pre-flight / push. Mirrors comments.sh / revise.sh.
if [ -n "$explicit_issue" ]; then
    case "$issue_dir" in
        */"$explicit_issue") : ;;
        *) die "ship.sh: requested issue '$explicit_issue' does not match active issue_dir '$issue_dir'" ;;
    esac
fi

# Phase 9 dependency pre-flight (warn unless --strict-deps was passed).
export DEVAGENT_STATE_DIR="$(devagent_home)/state"
if ! depends_ship_preflight "$project" "$issue_arg" "$strict_deps"; then
    exit 2
fi

branch="$(state_get "$project" branch 2>/dev/null || true)"
[ -n "$branch" ] || die "ship.sh: no branch in state (run /devagent:branch first)"

# Zero-diff guard: artifact-only issues have no commits to push/PR. rev-list the
# ISSUE BRANCH by name — source_dir's own HEAD need not be the issue branch (never is
# under a worktree); refs are shared, so "$branch" resolves regardless (#68). A
# rev-list FAILURE must not collapse into the destructive skip (fail-safe by
# direction, cf. commit.sh / #25): only skip when rev-list SUCCEEDED and was empty.
baseline_sha="$(state_get "$project" baseline_sha 2>/dev/null || true)"
source_dir="$(config_get_project_field "$project" source_dir)"
zd_commits=""; zd_ok=1
if [ -n "$baseline_sha" ]; then
    zd_commits="$("$DEVAGENT_GIT" -C "$source_dir" rev-list "$branch" "^$baseline_sha" 2>/dev/null)" || zd_ok=0
fi
if [ -n "$baseline_sha" ] && [ "$zd_ok" = 1 ] && [ -z "$zd_commits" ]; then
    info "ship.sh: no commits on branch — auto-marking step 15 [-] (zero-diff issue)"
    checklist_mark "$issue_dir/checklist.md" 15 -
    log_append "$issue_dir" ship "auto-skipped: zero commits on branch (artifact-only issue)"
    exit 0
fi

# #148: refuse to push a branch that differs from the working tree. Review (13)
# and redmr (14) fixes applied after commit (10) land in the working tree; with
# no commit step remaining, ship used to push without them (Issues #101/#102 →
# recovery PR #147). Untracked paths are excluded deliberately (build dirs,
# scratch files) — the review/redmr docs' git-add instruction covers the
# new-untracked-file fix variant. Worktree-aware like commit.sh's work_dir.
# Placed after the zero-diff guard so artifact-only issues still auto-skip.
worktree_path="$(state_get "$project" worktree_path 2>/dev/null || true)"
work_dir="${worktree_path:-$source_dir}"
# Fail closed when git cannot inspect work_dir (stale worktree_path from a
# clobbered/aborted session): a silent 0-count here would re-enable the exact
# stranded-fix push this gate exists to prevent.
"$DEVAGENT_GIT" -C "$work_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "ship.sh: work_dir $work_dir is not a usable git tree (stale worktree_path in state?) — refusing to ship unverified (#148)"
modified_count="$("$DEVAGENT_GIT" -C "$work_dir" status --porcelain --ignore-submodules=dirty 2>/dev/null | grep -cv '^??' || true)"
if [ "$modified_count" -gt 0 ]; then
    die "ship.sh: $modified_count modified tracked file(s) in $work_dir — commit review/redmr fixes (git add … && git commit -s) or stash unrelated edits before shipping; refusing to push a branch that differs from the working tree (#148)"
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

# Resolved early (#41): code_sh and target_repo are needed to pre-validate the
# stacked parent base on the target repo before the permission-gate plan and the
# #26 pre-flight below.
code_sh="$DEVAGENT_CODE_BACKEND_DIR/$code_backend.sh"
[ -x "$code_sh" ] || die "ship.sh: missing code backend $code_sh"
target_repo="$upstream_repo"
if [ "$fork_first" = "true" ] && [ -n "$fork_repo" ]; then
    target_repo="$fork_repo"
fi
ship_as_draft_global="$(config_get_default ship_as_draft 2>/dev/null || echo false)"
ship_as_draft_proj="$(config_get_project_field "$project" ship_as_draft 2>/dev/null || echo "$ship_as_draft_global")"
# Per-issue draft override: .devagent-draft forces draft state.
[ -r "$issue_dir/.devagent-draft" ] && ship_as_draft_proj="true"

push_remote="$(config_get_project_field "$project" source_remote 2>/dev/null || echo origin)"

# Resolve the PR base branch. Default = the project's default baseline (remote
# prefix stripped). #34: if baseline_sha is the tip of a local branch other than
# the default base, the issue is stacked on an unmerged parent — base the PR on
# that parent branch so its three-dot diff shows only the child's delta (GitHub
# diffs against the merge-base, correct even if the parent advances). Set at create
# time so no `gh pr edit --base` re-target (GraphQL-deprecation-prone) is needed.
# Resolved here (before #26 and the gate) for two reasons: the chosen base appears
# in the permission-gate plan, and the #26 fork-base pre-flight is skipped for a
# stacked child — #26 keeps the FORK's default base current, which is irrelevant
# when the PR bases on the parent, not the default base.
base_branch="$(config_get_project_field "$project" default_baseline | sed 's|^[^/]*/||')"
[ -n "$base_branch" ] || base_branch="main"
# #48: pass the issue branch as the child so advanced-parent (merge-base) and
# multi-candidate (ancestor-of-child) resolution can engage. `branch` is the
# state branch, resolvable in $source_dir even under a worktree (refs are shared).
parent_branch="$(stacked_parent_branch "$source_dir" "$baseline_sha" "$base_branch" "$push_remote" "$branch")"
if [ -n "$parent_branch" ]; then
    # #41: confirm the parent exists on the PR target repo before basing on it;
    # otherwise `gh pr create --base` surfaces a raw "base not found". On an
    # explicit rc==1 (absent) fall back to the default base + warn (which
    # re-enables the #26 pre-flight below); rc==0 (exists) or rc>=2 (backend
    # lacks the verb / network error) leaves the parent base unchanged.
    set +e
    "$code_sh" branch-exists "$target_repo" "$parent_branch" >/dev/null 2>&1
    _be_rc=$?
    set -e
    if [ "$_be_rc" -eq 1 ]; then
        warn "ship.sh: stacked parent '$parent_branch' not found on $target_repo — basing PR on default base '$base_branch' instead (#41)"
        parent_branch=""
    else
        # #154: branch-exists cannot tell a live parent from a DEAD one — a parent
        # whose own PR already SQUASH-merged still exists on the remote and still
        # satisfies the stacked topology, but basing a child PR on it strands the
        # child (the work never reaches the default base; close-keywords never fire).
        # Live: PR #152 based on PR #147's merged branch → reland #153. No git-only
        # predicate distinguishes this from a legitimate advanced parent, so ask the
        # forge. rc 0 = a merged PR has this head (dead) → fall back to the default
        # base + warn (re-enabling the #26 pre-flight); rc 1 = none (live) → keep;
        # rc >= 2 = verb absent / network error → leave unchanged (fail-open, exactly
        # like branch-exists). set +e mirrors the #41 block (ship runs under set -e).
        set +e
        "$code_sh" merged-pr-head "$target_repo" "$parent_branch" >/dev/null 2>&1
        _mph_rc=$?
        set -e
        if [ "$_mph_rc" -eq 0 ]; then
            warn "ship.sh: stacked parent '$parent_branch' has an already-merged PR (dead branch) on $target_repo — basing PR on default base '$base_branch' instead (#154; live PR #152/#153)"
            parent_branch=""
        else
            base_branch="$parent_branch"
            info "ship.sh: stacked child (baseline ${baseline_sha:0:12}) → basing PR on parent branch '$parent_branch' (#34)"
        fi
    fi
fi

# --- #26 Defect A: a stale fork base pollutes the PR's three-dot diff. ------
# Only when shipping against a fork whose default branch can lag upstream — and
# NOT for a stacked child (#34): its PR bases on the parent branch, so the fork's
# default-base currency is irrelevant and #26's main-based checks/FF must not fire.
ff_src=""; ff_dst=""; ff_plan=""
if [ -z "$parent_branch" ] && [ "$fork_first" = "true" ] && [ -n "$fork_repo" ]; then
    . "$DEVAGENT_ROOT/scripts/lib/upstream.sh"
    # || true to mirror the mergetoall guard: missing default_baseline no-ops
    # the pre-flight rather than aborting ship (it's a required field in
    # practice, but fail safe).
    up_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
    if [ -n "$up_ref" ]; then
        up_remote="${up_ref%%/*}"; base_br="${up_ref#*/}"
        fork_base="$push_remote/$base_br"                              # e.g. fork/main
        # Refresh BOTH refs: origin/main (upstream) and the fork base we may FF,
        # so the behind/FF-ability checks use current refs (a stale fork ref
        # could otherwise trigger a false hard-stop below).
        upstream_fetch "$source_dir" "$up_remote"
        upstream_fetch "$source_dir" "$push_remote"
        behind="$(upstream_behind_count "$source_dir" "$fork_base" "$up_ref")"
        if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
            # Upstream advanced. Hard-stop if the fork base has DIVERGED (carries
            # commits not on upstream) — it can't be fast-forwarded, so the PR
            # would open against a polluted base; the operator must reconcile it.
            if ! is_fast_forward "$source_dir" "$fork_base" "$up_ref"; then
                die "ship.sh: fork base $fork_base has diverged from $up_ref (carries commits not on upstream) and cannot be fast-forwarded — the PR would open against a polluted base. Reconcile the fork's default branch with $up_ref (e.g. reset/merge $fork_base to $up_ref on the fork) before shipping (#26)."
            fi
            # Hard-stop if the branch conflicts with upstream — FFing the base
            # would only surface the conflict on GitHub; rebase to resolve.
            if branch_conflicts_upstream "$source_dir" "$branch" "$up_ref"; then
                die "ship.sh: branch '$branch' conflicts with $up_ref — upstream changed files you touched. Rebase onto $up_ref and resolve before shipping (#26); refusing to ship a base that would conflict."
            fi
            ff_src="$up_ref"; ff_dst="refs/heads/$base_br"
            ff_plan="
  fast-forward: $fork_base → $up_ref ($behind commits behind)"
        fi
    fi
fi

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
  base:       $base_branch
  draft?:     $ship_as_draft_proj
  issue:      $issue_arg → on_ship${ff_plan}
EOF
)"
permission_gate "$project" push_mr "$plan"

# Push branch.
source_dir="$(config_get_project_field "$project" source_dir)"
( cd "$source_dir" && "$code_sh" push-branch "$push_remote" "$branch" )

# #26 Defect A: FF the fork base so the PR diff shows only this branch's work.
if [ -n "$ff_src" ]; then
    ( cd "$source_dir" && "$DEVAGENT_GIT" push "$push_remote" "$ff_src:$ff_dst" ) \
        || warn "ship.sh: fast-forward of fork base failed (non-FF or push denied); PR diff may include upstream commits (#26)"
fi

title_file="$issue_dir/.devagent-title"
[ -r "$title_file" ] || die "ship.sh: missing $title_file (run /devagent:branch first)"
title="$(tr -d '\n' < "$title_file")"

draft_flag=()
[ "$ship_as_draft_proj" = "true" ] && draft_flag=(--draft)

# include_coauthor strip-guard (issue #31): hand create-mr a filtered COPY of the
# PR body with any Co-Authored-By trailer removed, on opt-out projects. mr.md on
# disk is the durable record and stays untouched. Default-true guard.
# CRITICAL: the trap MUST stay inside this branch, paired with the mktemp — if it
# were hoisted out while mr_body_send still aliases $mr_body, the EXIT trap would
# delete mr.md itself. ship.sh has no other EXIT trap, so adding one here is safe.
include_coauthor="$(config_get_project_field "$project" include_coauthor 2>/dev/null || echo true)"
mr_body_send="$mr_body"
if [ "$include_coauthor" = "false" ]; then
    mr_body_send="$(mktemp)"
    trap 'rm -f "$mr_body_send"' EXIT
    cp "$mr_body" "$mr_body_send"
    strip_coauthor "$mr_body_send"
    # Fail closed: never ship a blank PR body (same class as the #25 zero-diff
    # guard above). "Blank" = no non-whitespace content (a body of only trailers
    # plus blank separators strips to whitespace, which is still non-zero bytes,
    # so test content not size). Only the strip path can empty the body; the
    # default path is left byte-identical, so this guard does not touch it.
    grep -q '[^[:space:]]' "$mr_body_send" \
        || die "ship.sh: PR body empty after Co-Authored-By strip (#31) — mr.md was all trailer/blank lines; nothing to ship."
fi

# #88: qualify the PR head as <fork_owner>:<branch> when the MR target repo's
# owner differs from the branch (fork / push-remote) owner. gh resolves --head's
# owner from --repo, so a fork-branch → upstream-repo MR needs the explicit owner
# or the head is unresolvable. Same-repo and fork_only (target_repo == fork_repo)
# keep a bare head. Orthogonal to base_branch, so the stacked-parent base logic
# (#34/#41/#154) is untouched. The branch owner is code_source.fork's owner.
head="$branch"
if [ -n "$fork_repo" ] && [ "${target_repo%%/*}" != "${fork_repo%%/*}" ]; then
    head="${fork_repo%%/*}:$branch"
fi

mr_url="$("$code_sh" create-mr "$target_repo" "$title" "$mr_body_send" "$head" "$base_branch" "${draft_flag[@]}")"
[ -n "$mr_url" ] || die "ship.sh: create-mr returned empty URL"

# Fire on_ship transition. Tolerate missing transition verb / failures per §11.
# Skipped under fork_only. Also skipped if the routed backend/repo isn't
# configured (e.g. Issue-Fork-* with no [issue_source_fork] block).
# #219 audit: this transition is intentionally NOT gated by permissions.
# transition_issue (which gates sync's autonomous on_merge). on_ship fires only
# inside an explicit, interactive ship that already passed the push_mr gate
# above — the consent is the ship action itself — so it is not the ungated
# autonomous mutation sync was.
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
