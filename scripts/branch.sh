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
    [ -n "$override_ref" ] || die "$baseline_file is empty (no baseline ref)"
    # Treat strictly as a git ref: reject anything outside the ref charset so a
    # marker can never inject shell metacharacters into the git invocations.
    case "$override_ref" in
    *[!A-Za-z0-9._/-]*) die "invalid baseline ref '$override_ref' in $baseline_file (allowed: A-Za-z0-9 . _ / -)" ;;
    esac
    baseline="$override_ref"
    baseline_override=1
fi

cd "$source_dir"
# First path component of a remote/branch baseline names the remote to fetch; for
# a purely local-branch baseline (e.g. dev/all-prs → "dev") it is not a configured
# remote, so the fetch fails harmlessly — the baseline still resolves locally and
# fetch_failed is never consulted on that path (see the resolution block below).
base_remote="$(echo "$baseline" | cut -d/ -f1)"
# Fetch that remote, but CAPTURE the outcome rather than uniformly absorbing it as
# "already up to date" (#244). A failed fetch against a *configured* remote means
# the remote was unreachable (offline, host down, auth, transient), not that the
# ref is absent — the post-fetch resolution block below uses fetch_failed to tell
# those apart. stderr is still suppressed so offline tests stay quiet.
fetch_failed=0
# #269: capture the fetch stderr (into a var, not the terminal — offline tests stay
# quiet) so the unreachable-remote die below can classify auth vs network. Order is
# load-bearing: 2>&1 binds stderr to the capture, THEN 1>/dev/null drops stdout.
fetch_err="$("$DEVAGENT_GIT" fetch --quiet "$base_remote" 2>&1 1>/dev/null)" || fetch_failed=1
# Resolve baseline ref.
if baseline_sha="$("$DEVAGENT_GIT" rev-parse --verify "$baseline" 2>/dev/null)"; then
    :
elif [ "$baseline_override" -eq 1 ]; then
    # An explicit per-issue override that does not resolve is a hard error —
    # NEVER silently fall back to HEAD or default_baseline (that is the #72
    # mis-base hazard). Fail before any branch is created.
    die "per-issue baseline '$baseline' does not resolve as a git ref in $source_dir; refusing to fall back"
else
    # Default-baseline path. Three outcomes, not two (#244):
    #  (a) remote NOT configured (offline / no-remote fixture) → fall back to
    #      HEAD, but LOUDLY.
    #  (b) remote configured but the fetch FAILED → the remote was unreachable
    #      (offline, host down, auth, transient). The ref may legitimately exist
    #      remotely; we just never reached it. Do NOT call it pruned/typo'd, and
    #      do NOT fall back to HEAD (would wrong-base on a network blip).
    #  (c) remote configured and the fetch SUCCEEDED but the ref still does not
    #      resolve → genuinely pruned/typo'd/deleted ref.
    # (b) and (c) both refuse a silent HEAD fallback — that is the #72 mis-base
    # hazard: stacking the branch on whatever is checked out (often the previous
    # issue's branch) so ship later bases the PR on the wrong parent.
    if "$DEVAGENT_GIT" remote get-url "$base_remote" >/dev/null 2>&1; then
        if [ "$fetch_failed" -eq 1 ]; then
            # #269: classify the captured fetch stderr (auth vs network vs rate-limit).
            # Ambiguous/unrecognized ⇒ keep today's grouped wording (never mis-assert).
            cause="$(conn_diag_message "$fetch_err" || true)"
            [ -n "$cause" ] || cause="the fetch failed: offline, host down, auth, or transient network error"
            die "default_baseline '$baseline' could not be confirmed — remote '$base_remote' is configured but unreachable ($cause); refusing to fall back to HEAD (would wrong-base) — reconnect and retry, or fix default_baseline if the ref is gone (#72, #244, #269)"
        fi
        die "default_baseline '$baseline' does not resolve though remote '$base_remote' was reached and fetched (pruned, typo'd, or deleted ref?); refusing to fall back to HEAD — fix default_baseline or restore the ref (#72)"
    fi
    warn "default_baseline '$baseline' unresolvable and remote '$base_remote' is not configured; falling back to HEAD ($("$DEVAGENT_GIT" rev-parse --short HEAD)) — the new branch will stack on the current checkout (#72)"
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
