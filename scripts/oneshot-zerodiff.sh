#!/usr/bin/env bash
# scripts/oneshot-zerodiff.sh — #595.
#
# WHAT THIS DECIDES, stated honestly: NOT "did this issue produce a diff" — that
# is unattributable. The source tree is SHARED: cleanup.sh:74 checks out the base
# branch on every close, a git pull lands other issues' work, and the tree may
# sit on any branch. Any two-point measurement of a shared tree attributes
# nothing (round 1 tried a pull-time SHA and had a strictly LARGER
# false-positive set than this basis).
#
# What IS decidable, and what the oneshot checklist's prose already promises
# ("an action that produces a diff belongs in the standard tier"):
#     the tree carries NO UNPUBLISHED CHANGE —
#     on the base branch, no commits beyond default_baseline, no uncommitted
#     paths.
# A one-shot closes with the tree as the published base left it. No message here
# asserts authorship; the refusal prints what it found and asks the operator to
# judge.
#
# Usage: oneshot-zerodiff.sh <project> [issue-id]
#
# Verdict line, one spelling per outcome (register Issue-586); the verdict is
# the only machine-read field, so no number beside it can drift:
#   oneshot-zerodiff: <verdict> basis=<ref>@<sha|unresolved> branch=<n|DETACHED> tree=<dir>
# basis/branch/tree are stamped AND branch is COMPARED to the base branch
# (register project Issue-69; workflow ambient-scope entry: "stamp the resolved
# SHA/tree and compare it to the branch before trusting any number"). A stamp
# alone records the wrong basis instead of hiding it; the comparison is the
# mitigation.
#
# Exit codes, distinct at the SOURCE so no caller parses prose (Issue-458):
#   0 n/a            not a oneshot issue
#   0 clean          on the base branch, no unpublished commits, no dirty paths
#   3 violated       unpublished commits and/or uncommitted paths
#   4 indeterminate  cannot classify — FAIL SAFE, never authorizes completion.
#                    Six separately-worded causes, each naming its remedy: the
#                    tree is on another branch (the ROUTINE trigger — a sibling
#                    issue's branch is checked out and cleanup restores the base
#                    only AFTER this gate), a stale recorded worktree_path, an
#                    unset/missing/non-git source_dir, an unset default_baseline,
#                    an unresolvable default_baseline, a faulted git status.
#   5 acknowledged   .devagent-oneshot-ack present — operator escape seam
#   1 usage error ONLY. Every tree/state/config fault above is 4, never 1: a
#     fault must not be reported as a boundary verdict.
#
# LIMITS — each with its own fixture row, because a LIMITS list is itself a set
# of claims (register Issue-583):
#  * Gitignored paths are uncounted. `git status --porcelain` omits them by
#    design, and this repo ignores the analyzer's own build-*/ dirs for exactly
#    that reason (#324/#351).
#  * NO fetch. Cleanup does no network I/O. A stale remote-tracking ref can only
#    make this STRICTER — work already merged upstream but absent from the local
#    ref reads as unpublished, a loud false positive whose remedy (`git fetch`)
#    the message names. It cannot fail open.
#  * default_baseline is resolved HERE with `rev-parse --verify` and NEVER falls
#    back to HEAD. baseline_resolve() does fall back (baseline.sh:106-107),
#    which is correct for "where do I cut a branch from" and fail-OPEN here: it
#    would compare the tree against itself and print `clean`. A different
#    question deserves a different resolver (register Issue-565).
#  * No pipeline in this file has an early-closing reader. `git … | head` under
#    `set -o pipefail` dies with SIGPIPE (rc 141) past the tenth line and would
#    truncate the refusal BEFORE its remedies (round-2 improve B2, reproduced) —
#    every list is captured into a variable first and truncated with a single
#    `sed -n '1,10…p' <<<` (register Issue-314/589).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=lib/zerodiff.sh
. "$DEVAGENT_ROOT/scripts/lib/zerodiff.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

# Target resolution: arg -> pin -> shared state (the cleanup.sh/#331 chain). The
# pin is VALIDATED before it reaches a path — a traversal pin would otherwise
# measure another issue's dir.
issue_arg="${2:-}"; issue_arg="${issue_arg##*/}"
[ "$issue_arg" != "--" ] || issue_arg=""
[ -n "$issue_arg" ] || issue_arg="${DEVAGENT_ACTIVE_ISSUE:-}"
if [ -n "$issue_arg" ]; then
    _state_issue_id_ok "$issue_arg" \
        || die "invalid issue id '$issue_arg' (allowed: A-Za-z0-9 _ -)"
    issue_dir="$(issue_dir_for "$project" "$issue_arg")"
else
    issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
fi
[ -d "$issue_dir" ] || die "issue_dir not set or missing"

emit() {
    printf 'oneshot-zerodiff: %s basis=%s branch=%s tree=%s\n' "$1" "$2" "$3" "$4"
}

# Tier gate. cleanup.sh reads the tier itself and only invokes this script on a
# oneshot, so this branch serves DIRECT invocation (the step-11 verify beat, an
# operator hand-run) and keeps both consumers on one predicate.
tier="$(checklist_template_name "$issue_dir/checklist.md")"
if [ "$tier" != oneshot ]; then
    emit n/a - - -
    exit 0
fi

# The acknowledged escape seam. A fail-closed verdict with no operator seam
# turns every configuration outside the validated set from "unsupported" into
# "unshippable" (register Issue-466), so one exists — checked BEFORE any
# measurement, because its purpose is trees this cannot measure. `-s` not `-e`:
# a zero-byte file is an accident, and an accident must not read as consent.
# Per-issue and persistent: it is only ever READ on the oneshot path, so a
# retier out of oneshot leaves it inert rather than stale. Deliberately NOT
# offered as the remedy for a `violated` verdict; in the refusal text below it
# is ordered last and labelled.
ack="$issue_dir/.devagent-oneshot-ack"
if [ -s "$ack" ]; then
    emit acknowledged - - -
    warn "oneshot boundary NOT CHECKED for $issue_arg — $ack records an operator acknowledgement: $(head -1 "$ack"). This is a reviewed de-scoping, not a clean verdict (#595)."
    exit 5
fi

# Pre-flight BOTH of active_tree_resolve's die branches (active.sh:384-385 and
# :391-392) so neither can surface as a boundary verdict — a state or config
# fault is `indeterminate` with its real reason, not rc 1 (round-1 SE4, round-2
# B6: the worktree branch is reachable after `revise.sh --retier oneshot` on a
# project that already ran step 8, so "unreachable by construction" was false).
wt="$(state_ctx_get "$project" worktree_path "$issue_arg" 2>/dev/null || true)"
case "$wt" in null|'""') wt="" ;; esac
if [ -n "$wt" ]; then
    if ! "$DEVAGENT_GIT" -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        emit indeterminate - - "$wt"
        warn "recorded worktree_path '$wt' is not a usable git tree — a state fault (stale worktree_path from an aborted session?), not a boundary verdict. Cannot classify (#595)."
        exit 4
    fi
else
    src="$(config_get_project_field "$project" source_dir 2>/dev/null || true)"
    if [ -z "$src" ] || [ ! -d "$src" ]; then
        emit indeterminate - - "${src:-<unset>}"
        warn "source_dir is unset or missing for '$project' — a configuration fault, not a boundary verdict. Cannot classify (#595)."
        exit 4
    fi
    if ! "$DEVAGENT_GIT" -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        emit indeterminate - - "$src"
        warn "source_dir '$src' is not a git work tree — cannot classify (#595)."
        exit 4
    fi
fi
# Both die branches are now excluded, so this is the one authoritative resolver
# (recorded worktree, else source_dir — register Issue-590) and cannot die.
active_tree_resolve "$project" "$issue_arg"
tree="$ACTIVE_TREE_DIR"

branch="$("$DEVAGENT_GIT" -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$branch" ] && [ "$branch" != HEAD ] || branch=DETACHED

base_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
if [ -z "$base_ref" ]; then
    emit indeterminate "<unset>" "$branch" "$tree"
    warn "no default_baseline configured for '$project' — nothing to measure 'published' against. Cannot classify (#595)."
    exit 4
fi
base_sha="$("$DEVAGENT_GIT" -C "$tree" rev-parse --verify "$base_ref" 2>/dev/null)" || base_sha=""
if [ -z "$base_sha" ]; then
    emit indeterminate "$base_ref@unresolved" "$branch" "$tree"
    warn "default_baseline '$base_ref' does not resolve in $tree — refusing to fall back to HEAD, which would compare the tree against itself and report a clean verdict. Fetch the ref or fix default_baseline, then re-run (#595)."
    exit 4
fi
basis="$base_ref@$base_sha"

# The branch COMPARISON (not just the stamp). The same derivation cleanup.sh:63
# uses for its own restore, so the two agree on what "the base branch" means.
# This is the gate's ROUTINE trigger (register volk Issue-Fork-165 / lawfirm
# Issue-8: name the routine action in the message): the shared tree is often on
# a sibling issue's in-flight branch, because cleanup.sh:74 is the only thing
# that restores the base and it runs AFTER this gate. From another branch
# "published state" cannot be judged — rev-list would list the sibling's live
# work as "unpublished" and the retier remedy would be a false diagnosis.
base_branch="${base_ref##*/}"
if [ "$branch" != "$base_branch" ]; then
    emit indeterminate "$basis" "$branch" "$tree"
    warn "the source tree is on '$branch', not the base branch '$base_branch' — routine (a sibling issue's branch is checked out; cleanup restores the base only after this gate), but published state cannot be judged from here. Remedy: git -C '$tree' checkout '$base_branch' (stash or commit anything you want to keep first), then re-run (#595)."
    exit 4
fi

# The commits half: the SHARED three-verdict contract, called unchanged. Its
# fail-safe direction (a git fault or an empty baseline => indeterminate, never
# skippable) is the invariant three other callers depend on; this caller maps
# the same three verdicts to its own actions rather than weakening any of them.
verdict="$(zero_diff_classify "$DEVAGENT_GIT" "$tree" HEAD "$base_sha")"

# The dirty half — required, not belt-and-braces: a dirty-only tree classifies
# as `empty` (measured, U1), so commits-only measurement would miss half of AC1.
# git's rc is read in THIS shell: `2>/dev/null` alone would collapse ABSENT and
# CANNOT-DETERMINE into one empty result and report a faulted status as a clean
# tree (register fleet Issue-73).
dirty_out=""; dirty_ok=1
dirty_out="$("$DEVAGENT_GIT" -C "$tree" status --porcelain 2>/dev/null)" || dirty_ok=0
if [ "$dirty_ok" -ne 1 ]; then
    emit indeterminate "$basis" "$branch" "$tree"
    warn "git status failed in $tree — cannot classify the working tree, and an unprovable invariant must not read as clean (#595)."
    exit 4
fi

case "$verdict" in
    empty)   violated=0 ;;
    commits) violated=1 ;;
    *)
        emit indeterminate "$basis" "$branch" "$tree"
        warn "zero_diff_classify returned '${verdict:-unknown}' against $basis in $tree — fail-safe: this never authorizes completion (#595)."
        exit 4
        ;;
esac
[ -z "$dirty_out" ] || violated=1

if [ "$violated" -eq 0 ]; then
    emit clean "$basis" "$branch" "$tree"
    exit 0
fi

# Capture BEFORE printing (see LIMITS: no early-closing reader anywhere). The
# `|| true` is safe: the verdict already came from zero_diff_classify, this
# list is display only, and an empty list prints nothing.
commits_list=""
if [ "$verdict" = commits ]; then
    commits_list="$("$DEVAGENT_GIT" -C "$tree" log --oneline HEAD "^$base_sha" 2>/dev/null || true)"
fi

emit violated "$basis" "$branch" "$tree"
{
    printf 'oneshot boundary VIOLATED for %s — the source tree carries UNPUBLISHED CHANGES, and a one-shot must close with the tree as the published base left it.\n' "$issue_arg"
    printf '  tree:   %s (on %s)\n' "$tree" "$branch"
    printf '  basis:  %s\n' "$basis"
    if [ -n "$commits_list" ]; then
        printf '  commits not in %s (first 10):\n' "$base_ref"
        sed -n '1,10s/^/    /p' <<<"$commits_list"
    fi
    if [ -n "$dirty_out" ]; then
        printf '  uncommitted paths (first 10):\n'
        sed -n '1,10s/^/    /p' <<<"$dirty_out"
    fi
    # Remedies fix-first, with the silencing path last and labelled — a
    # first-listed remedy can be the guard's own bypass (register lawfirm
    # Issue-8). This gate CANNOT attribute, so it says so rather than accusing:
    # the tree is shared. And the retier's cost is stated, because a remedy
    # that understates its own cost pushes operators toward the silencing seam.
    printf '  THIS DOES NOT ASSERT THE ONE-SHOT WROTE THEM — the tree is shared. Judge the lists above, then:\n'
    printf '  If this one-shot produced them, escalate the tier:\n'
    printf '    bash %s/scripts/revise.sh %s %s --retier standard\n' \
        "$DEVAGENT_ROOT" "$project" "$issue_arg"
    printf '    (a revision: appends the standard rows and RESTARTS THE ISSUE AT DRAFT (step 2) — the full standard rail from there; never destructive)\n'
    printf '  If they are NOT this one-shot'\''s, land them or clear them and re-run — commit and push, or `git fetch` when %s is merely stale locally. Do not discard work you have not inspected.\n' "$base_ref"
    printf '  Reviewed de-scoping only: `echo "<reason>" > %s` records an acknowledgement and skips this check for this issue (persists across revisions).\n' "$ack"
} >&2
exit 3
