#!/usr/bin/env bash
# scripts/spike.sh — workflow step 3 (OPTIONAL, flag-driven). Manages the
# lifecycle of a THROWAWAY worktree in which the spike step tests a plan's
# load-bearing unknowns. Spike code is EVIDENCE, never product: nothing here is
# merged, cherry-picked, or copied — the worktree and its temp branch are destroyed.
#
# LIFECYCLE — two explicit subcommands, deliberately NOT a single script with an
# EXIT trap. A setup script's EXIT trap fires when SETUP ends, which would delete
# the worktree before the executor could spike in it (#536 improve B8):
#   spike.sh create   <project> [issue]   -> worktree at the RESOLVED baseline; prints its path
#   spike.sh teardown <project> [issue]   -> idempotent destroy + state clear
#
# git mechanics validated empirically on a scratch repo before being relied on
# (Issue-33), because each of these refuses the naive form:
#   * a spike worktree has uncommitted edits  -> `worktree remove` needs --force
#   * a branch checked out in a worktree      -> cannot be deleted; REMOVE FIRST
#   * a spike that committed                  -> `branch -d` refuses; needs -D
#   * bash EXIT does not run on SIGTERM/SIGHUP -> those are trapped explicitly
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
# shellcheck source=lib/log.sh
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
# shellcheck source=lib/conn-diag.sh
. "$DEVAGENT_ROOT/scripts/lib/conn-diag.sh"
# shellcheck source=lib/baseline.sh
. "$DEVAGENT_ROOT/scripts/lib/baseline.sh"

: "${DEVAGENT_GIT:=git}"

usage() { printf 'usage: spike.sh <create|teardown> <project> [Issue-N]\n' >&2; }

action="${1:-}"
case "$action" in
create | teardown) ;;
*)
    usage
    die "first argument must be 'create' or 'teardown'"
    ;;
esac

project="${2:-}"
[ -n "$project" ] || { usage; die "project required"; }
config_is_project "$project" || die "unknown project '$project'"

issue_arg="${3:-}"
if [ -z "$issue_arg" ]; then
    # #240: a mutating step never acts on a scan-GUESSED issue — pin/state only.
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_dir_for "$project" "$issue_arg")"
[ -d "$issue_dir" ] || die "issue dir not found: $issue_dir"

# #422/#332 derivation — strip ONLY "Issue-" and lowercase, so Issue-42 and
# Issue-Fork-42 get DISTINCT names. The bare numeric form (which also strips
# "Fork-") collapsed the twins onto one branch/leaf and died "already exists";
# both prior issues exist because of that bug, so do not reintroduce it here.
spike_id="$(printf '%s' "${issue_arg#Issue-}" | tr '[:upper:]' '[:lower:]')"
spike_branch="spike/$spike_id"
spike_leaf="issue-$spike_id-spike"

# _spike_destroy <source_dir> <path> — idempotent teardown of one worktree+branch.
# Order is load-bearing: the worktree must go BEFORE the branch (a checked-out
# branch cannot be deleted). Both steps tolerate absence so teardown can be run
# twice, or after a crash that left only one of the pair behind.
# _spike_destroy <source_dir> <path> <own_branch>
# <own_branch> is 1 ONLY when this step created (or recorded) the branch. The path
# ownership check alone is not enough: deleting `spike/<id>` unconditionally destroys
# a same-named branch a human made, unmerged, with exit 0 (#536 redmr BLOCKING).
_spike_destroy() {
    local sdir="$1" path="$2" own_branch="${3:-0}"
    ( cd "$sdir" || exit 1
      if [ -n "$path" ] && [ -e "$path" ]; then
          "$DEVAGENT_GIT" worktree remove --force "$path" >/dev/null 2>&1 || true
      fi
      # prune records of worktrees whose directory vanished (crash case)
      "$DEVAGENT_GIT" worktree prune >/dev/null 2>&1 || true
      if [ "$own_branch" = "1" ] \
         && "$DEVAGENT_GIT" show-ref --verify --quiet "refs/heads/$spike_branch"; then
          "$DEVAGENT_GIT" branch -D "$spike_branch" >/dev/null 2>&1 || true
      fi
      # POST-CONDITION (#536 review BLOCKING-1): a destroy that only ATTEMPTED is
      # worse than no destroy — the caller would clear spike_worktree_path and the
      # orphan would survive with its only pointer erased. Verify, then report.
      [ -z "$path" ] || [ ! -e "$path" ] || exit 1
      [ "$own_branch" != "1" ] \
        || ! "$DEVAGENT_GIT" show-ref --verify --quiet "refs/heads/$spike_branch" || exit 1 )
}

case "$action" in
create)
    # Resolve the baseline through the SHARED resolver (#536): the spike worktree
    # is cut at the SAME baseline branch.sh would use — never at the issue branch
    # (branch is step 6; the plan phase stays no-code in the real tree) and never
    # at HEAD (the #72 mis-base hazard).
    baseline_resolve "$project" "$issue_dir"
    source_dir="$BASELINE_SOURCE_DIR"

    worktree_root="$(config_get_project_field "$project" worktree_root 2>/dev/null || echo "$source_dir-wt")"
    spike_path="$worktree_root/$spike_leaf"

    # PRE-FLIGHT RECLAIM: a crashed prior run leaves a worktree and/or branch that
    # would make `worktree add` die before any cleanup could run. Reclaim first so
    # the step is re-runnable (#536 improve).
    prev="$(state_ctx_get "$project" spike_worktree_path "$issue_arg" 2>/dev/null || true)"
    # Reclaim ONLY what a prior spike run left: a recorded path, or a worktree at the
    # path we are about to use. A `spike/<id>` branch with NO associated worktree was
    # not made by us (#536 review) — refuse rather than force-delete someone's work.
    if [ -z "${prev:-}" ] && [ ! -e "$spike_path" ] \
       && ( cd "$source_dir" && "$DEVAGENT_GIT" show-ref --verify --quiet "refs/heads/$spike_branch" ); then
        die "branch '$spike_branch' already exists but no spike worktree is recorded — refusing to delete a branch this step did not create; remove it yourself if it is stale"
    fi
    _spike_destroy "$source_dir" "${prev:-}" 1 || die "could not reclaim the previous spike worktree ($prev)"
    _spike_destroy "$source_dir" "$spike_path" 1 || die "could not reclaim a stale spike worktree at $spike_path"

    # Partial-setup guard: if `worktree add` dies midway (or the run is signalled),
    # do not strand a half-made worktree. Disarmed on success. EXIT alone misses
    # signals, so INT/TERM/HUP are trapped explicitly.
    # A bash signal handler RUNS and then execution RESUMES — without an explicit
    # exit, a SIGTERM after `worktree add` would destroy the tree, then record a
    # path to nothing and exit 0 reporting success (#536 review BLOCKING-2).
    # A failed cleanup must be ANNOUNCED and the orphan RECORDED — swallowing it
    # (`|| true`) reproduces the very "orphan lives, pointer erased" shape the
    # teardown post-condition was added for (#536 redmr MAJOR).
    _spike_cleanup_partial() {
        if _spike_destroy "$source_dir" "$spike_path" 1; then return 0; fi
        state_ctx_set_many "$project" "$issue_arg" str spike_worktree_path "$spike_path" || true
        warn "spike setup failed AND cleanup failed — worktree '$spike_path' and/or branch '$spike_branch' SURVIVE; spike_worktree_path left set so they stay findable. Remove them by hand, then re-run."
    }
    _spike_abort() { _spike_cleanup_partial; exit 1; }
    trap _spike_cleanup_partial EXIT
    trap _spike_abort INT TERM HUP

    mkdir -p "$worktree_root"
    ( cd "$source_dir" && "$DEVAGENT_GIT" worktree add -b "$spike_branch" "$spike_path" "$BASELINE_SHA" ) \
        || die "could not create worktree $spike_path at $BASELINE_SHA"

    # Test seam: force the post-`worktree add` failure path so the partial-setup
    # guard is exercisable (the AC asks for born-red on failure; without a seam
    # nothing in the suite can make create fail after the worktree exists).
    [ -z "${DEVAGENT_SPIKE_FAIL_AFTER_ADD:-}" ] || die "forced failure after worktree add (test seam)"
    # Sibling seam: hold the process alive after `worktree add` so a test can deliver
    # a real SIGTERM and exercise the SIGNAL half of the partial-setup guard (the
    # half that had zero coverage — #536 redmr MAJOR).
    [ -z "${DEVAGENT_SPIKE_SLEEP_AFTER_ADD:-}" ] || sleep "$DEVAGENT_SPIKE_SLEEP_AFTER_ADD"

    state_ctx_set_many "$project" "$issue_arg" str spike_worktree_path "$spike_path"
    log_append "$issue_dir" spike "worktree $spike_path created at $BASELINE_REF ($BASELINE_SHA), branch $spike_branch"

    trap - EXIT INT TERM HUP
    printf '%s\n' "$spike_path"
    printf 'spike: worktree ready at %s (baseline %s, branch %s)\n' "$spike_path" "$BASELINE_REF" "$spike_branch" >&2
    ;;

teardown)
    source_dir="$(config_get_project_field "$project" source_dir)"
    # Only ever destroy the path THIS issue recorded — never a path we did not
    # create (two sessions on one issue must not tear down each other's tree).
    recorded="$(state_ctx_get "$project" spike_worktree_path "$issue_arg" 2>/dev/null || true)"
    # State is cleared ONLY on a VERIFIED destroy. Clearing it after a failed destroy
    # would erase the only pointer to a surviving orphan (#536 review BLOCKING-1).
    # own_branch=1 only when this issue actually recorded a spike worktree. With no
    # record there is nothing of ours to delete, and `spike/<id>` may be a human's
    # branch — never destroy it (#536 redmr BLOCKING).
    own=0; [ -n "${recorded:-}" ] && own=1
    _spike_destroy "$source_dir" "${recorded:-}" "$own" \
        || die "teardown FAILED — worktree and/or branch '$spike_branch' survived; spike_worktree_path left set to '${recorded:-}' so the orphan stays findable"
    state_ctx_set_many "$project" "$issue_arg" str spike_worktree_path '""'
    log_append "$issue_dir" spike "worktree torn down (${recorded:-none}); branch $spike_branch $([ "$own" = 1 ] && printf "removed (verified)" || printf "not owned — left untouched")"
    if [ "$own" = 1 ]; then
        printf 'spike: torn down %s (worktree and branch verified gone)\n' "$recorded" >&2
    else
        printf 'spike: nothing recorded for this issue — no worktree removed, branch %s left untouched\n' "$spike_branch" >&2
    fi
    ;;
esac
