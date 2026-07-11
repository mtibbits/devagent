#!/usr/bin/env bash
# scripts/commit.sh — workflow step 10. Compose commit message from
# commit_template, substitute placeholders, strip "(1M context)", commit -s.
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
# shellcheck source=lib/artifact.sh
. "$DEVAGENT_ROOT/scripts/lib/artifact.sh"
# shellcheck source=lib/coauthor.sh
. "$DEVAGENT_ROOT/scripts/lib/coauthor.sh"
# shellcheck source=lib/zerodiff.sh
. "$DEVAGENT_ROOT/scripts/lib/zerodiff.sh"

: "${DEVAGENT_GIT:=git}"

# #251 — opt-in scoped auto-staging. Stage EXACTLY the issue's declared in-scope
# paths (from a .devagent-scope manifest), never "everything dirty". Returns 0
# iff it staged at least one in-scope path; returns non-zero (caller falls back to
# the #25 die-loud guard) when scope can't be reliably determined or nothing was
# staged. Safety: per-path validation rejects the `git add -A`/`.`/`*`/flag
# vectors, and `git add --` stops a leading-dash path from being read as a flag.
#   autostage_in_scope <git> <work_dir> <scope_file>
autostage_in_scope() {
    local git="$1" work_dir="$2" scope_file="$3"
    [ -r "$scope_file" ] || return 1
    local line paths=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"    # rtrim
        [ -n "$line" ] || continue                # skip blank / whitespace-only lines
        # Reject every over-capture / injection vector → caller dies loud. Each
        # accepted entry must name a single in-repo FILE; anything that could make
        # `git add` match more than that one path is rejected:
        case "$line" in
            -*)                 return 1 ;;  # flag injection (-A, --all, ...)
            :*)                 return 1 ;;  # pathspec magic (:(top), :/) = whole-repo
            /*)                 return 1 ;;  # absolute path
            .|..|../*|*/..|*/../*) return 1 ;;  # cwd / parent-traversal
            *'*'*|*'?'*|*'['*)  return 1 ;;  # glob metacharacters
        esac
        # A directory entry would make `git add -- dir/` recurse and stage every
        # untracked sibling under it (the exact over-capture the feature forbids).
        # Require a file: reject anything that resolves to a directory. A staged
        # deletion (path gone from disk) is not a dir, so that legit case passes.
        [ -d "$work_dir/$line" ] && return 1
        paths+=("$line")
    done < "$scope_file"
    [ "${#paths[@]}" -gt 0 ] || return 1
    # Stage only the declared file paths (`--` ends option parsing; the validation
    # above guarantees each is a single in-repo file). A failure here (bad
    # pathspec) must not auto-skip — return non-zero so the caller dies loud.
    "$git" -C "$work_dir" add -- "${paths[@]}" 2>/dev/null || return 1
    # The manifest paths may not have been dirty (typo / already committed): if the
    # index is still empty, nothing was staged → do NOT proceed to an empty commit.
    if "$git" -C "$work_dir" diff --cached --quiet 2>/dev/null; then
        return 1
    fi
    return 0
}

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

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue dir not found: $issue_dir"
# (#240 supersedes the #70 arg-vs-state crosscheck: an explicit arg IS the
# issue — branch/keys now come from ITS [context] table, so a mismatched arg
# can no longer commit the active branch under the wrong {{issue}}; an issue
# with no recorded branch dies loudly at the #69 guard below.)

# Zero-diff guard — decided on the WORKING TREE, not commits-ahead (issue #25).
# commit.sh commits the staged index (`git commit -s -F` below); the implement
# step commits per-task and may leave a remainder in the working tree (#116).
# Four cases:
#   staged changes present     -> fall through and commit them (normal path)
#   dirty but nothing staged   -> fail loudly (or #251 autostage); never
#                                 silently skip real work — even when commits
#                                 already exist ahead of baseline
#   clean tree AND commits     -> per-task commits captured everything;
#                                 no-op success, mark [x] and exit (#116)
#   clean tree AND no commits  -> genuine artifact-only, auto-mark [-] and exit
source_dir="$(config_get_project_field "$project" source_dir)"
worktree="$(state_ctx_get "$project" worktree_path "$issue_arg" 2>/dev/null || true)"
work_dir="${worktree:-$source_dir}"

# Success epilogue for step 10 — shared by the real-commit tail and the #116
# no-op path so the two cannot drift. $1 = log message (caller appends NOTE).
finish_step() {
    state_ctx_set_many "$project" "$issue_arg" str last_step "10" str last_step_name "commit"
    checklist_mark "$issue_dir/checklist.md" 10 x
    log_append "$issue_dir" commit "$1"
    checklist_print_next_hint "$issue_dir/checklist.md"
}

# #69: commit on the issue branch only. This guard runs BEFORE the zero-diff
# guard so no early-exit path (no-op success, artifact-only skip) can mark
# step 10 while HEAD sits on the wrong branch (e.g. all_prs after mergetoall,
# or the base branch after cleanup, in the revision flow). A detached HEAD
# yields an empty name and is also refused. Checked on work_dir, whose HEAD
# IS the issue branch under a worktree too.
branch="$(state_ctx_get "$project" branch "$issue_arg" 2>/dev/null || true)"
# #240: an issue-keyed session (env pin / explicit arg) with no recorded
# branch must die loudly, not fall through the empty-branch tolerance below —
# that tolerance exists for legacy bare flows only.
if [ -z "$branch" ] && { [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ] || [ -n "${2:-}" ]; }; then
    die "no branch recorded for '$issue_arg' — run /devagent:branch first"
fi
# #316: an empty recorded branch with a COMPLETED branch step (6) is state
# corruption — the branch step ran (a branch existed) but the recorded branch is
# now gone. This is the resume-after-cleanup kill chain: cleanup GC'd the issue's
# [context.<issue>] table but left it parked, so a later BARE resume (no pin, no
# arg — which the #240 guard above does NOT cover) restored defaults (branch="").
# Without this, the empty-branch tolerance below would commit staged work onto
# whatever HEAD is on (the base branch post-cleanup) and mark step 10 [x]. Gate
# on the branch step being DONE ([x]) — not skipped ([-]) or pending ([ ]/[~]) —
# so the legitimate never-branched legacy flow keeps its empty-branch tolerance.
if [ -z "$branch" ]; then
    branch_step="$(checklist_step_state_by_name "$issue_dir/checklist.md" branch 2>/dev/null || true)"
    if [ "$branch_step" = "x" ]; then
        die "branch step is complete but no branch is recorded for '$issue_arg' — state is incoherent (resume-after-cleanup? run /devagent:doctor). Restore the issue's branch ('/devagent:branch') before committing (#316)."
    fi
fi

# #362: born-red gate — die iff the LATEST born-red artifact is FLAGGED (a new test
# that was GREEN at baseline, i.e. never-red / vacuous). Absent / PASS / PASS
# (allowed) / NO-NEW-TESTS never fire: projects without born_red=true write no
# artifact, so non-bats projects (volk) and artifact-only issues are untouched
# (the #316 fire-precisely lesson).
_br_latest="$(ls -1 "$issue_dir/analysis/"*-born-red.txt 2>/dev/null | sort | tail -1 || true)"
# #409: when born_red=true is configured, an ABSENT artifact means the
# implement-phase born-red run was skipped — the largest silent-skip bypass of
# the #333 flagship. Die loud. (born_red=false — volk / non-bats projects — never
# reach here, so they are untouched; the #316 fire-precisely lesson.) A run that
# finds no new tests still writes a NO-NEW-TESTS artifact, so this is coherent.
_born_red="$(config_get_project_field "$project" born_red 2>/dev/null || echo false)"
if [ "$_born_red" = "true" ] && [ -z "$_br_latest" ]; then
    die "born-red gate: born_red=true but no born-red artifact exists at $issue_dir/analysis/<date>-born-red.txt — the implement-phase born-red run was skipped. Run it (bash \"\$CLAUDE_PLUGIN_ROOT/scripts/born-red.sh\" $project) before committing; a change with no new tests still writes a NO-NEW-TESTS artifact that satisfies this gate (#362/#409)."
fi
if [ -n "$_br_latest" ] && grep -q '^verdict: FLAGGED' "$_br_latest"; then
    die "born-red gate: $_br_latest reports FLAGGED — a new test is green at baseline (never-red / vacuous). Make it fail without the change, or allowlist it (with a reason) in $issue_dir/.devagent-born-red-allow, then re-run /devagent:born-red (#362)."
fi
# #410: staleness guard — the artifact pins the tests/ delta born-red judged
# (born_red_tests_fingerprint). If the set has drifted since (a test added/edited/
# removed after the run), the recorded PASS is stale — die. Grandfather artifacts
# with no fingerprint line (older format). Skip if baseline is unknown.
if [ -n "$_br_latest" ]; then
    _br_fp="$(sed -n 's/^tests-fingerprint: //p' "$_br_latest" | head -1)"
    _br_baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
    if [ -n "$_br_fp" ] && [ -n "$_br_baseline" ]; then
        _cur_fp="$(born_red_tests_fingerprint "$source_dir" "$_br_baseline")"
        [ "$_br_fp" = "$_cur_fp" ] || die "born-red gate: the tests/ set changed since born-red ran ($_br_latest pinned $_br_fp, now $_cur_fp) — a test was added/edited/removed after the check, so its PASS is stale. Re-run scripts/born-red.sh to re-judge, then commit (#410)."
    fi
fi

cur_branch="$("$DEVAGENT_GIT" -C "$work_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -n "$branch" ] && [ "$cur_branch" != "$branch" ]; then
    die "refusing to commit — $work_dir is on '${cur_branch:-(detached HEAD)}' but the issue branch is '$branch'. Check out '$branch' ('git -C $work_dir checkout $branch') then re-run (#69)."
fi

staged=""
# Fail-safe by direction: any git fault here (e.g. not-a-repo, exit >=2) takes
# the `|| staged=1` branch, so the guard falls through to `git commit` below
# which fails loudly — never a silent skip. `dirty`'s `|| true` masks the same
# fault to "", but staged=1 has already won, so it can't re-introduce the skip.
"$DEVAGENT_GIT" -C "$work_dir" diff --cached --quiet 2>/dev/null || staged=1
dirty="$("$DEVAGENT_GIT" -C "$work_dir" status --porcelain 2>/dev/null || true)"

if [ -z "$staged" ]; then
    if [ -n "$dirty" ]; then
        # #251: opt-in scoped auto-staging. When commit_autostage=true AND the
        # issue declares an in-scope manifest, stage exactly those paths and fall
        # through to the commit below — instead of forcing a manual `git add`.
        # Default off, or any can't-determine/nothing-staged case, → the #25
        # die-loud guard. Out-of-scope dirty files are never in the manifest, so
        # they are never staged (provably absent from the commit). Reached even
        # when commits exist ahead of baseline (#116): a dirty-unstaged
        # remainder on top of per-task commits is forgotten work.
        autostage="$(config_get_project_field "$project" commit_autostage 2>/dev/null || echo false)"
        if [ "$autostage" = "true" ]; then
            # Autostage requested: stage exactly the manifest's files, or die with a
            # manifest-specific message (never the silent skip, never over-capture).
            if autostage_in_scope "$DEVAGENT_GIT" "$work_dir" "$issue_dir/.devagent-scope"; then
                info "auto-staged in-scope files from .devagent-scope (commit_autostage=true, #251)"
            else
                die "commit_autostage=true but no in-scope file was staged from $issue_dir/.devagent-scope — the manifest is missing/empty, has an invalid entry (only single in-repo FILE paths are allowed; no '.', '..', absolute, ':' pathspec-magic, glob, or directory entries), or its paths are not dirty. Fix .devagent-scope or stage manually ('git add ...'). Refusing to silently skip (#25/#251)."
            fi
        else
            die "working tree has uncommitted changes but nothing is staged — stage your in-scope files ('git add ...') then re-run. Refusing to silently skip the commit step (would ship an empty PR; see issue #25)."
        fi
    else
        # Tree is clean — consult the commits-ahead classifier (#241) only now,
        # off the normal commit path. Three-way per the zerodiff.sh contract:
        # 'empty' is the only skip-authorizing verdict, and 'indeterminate'
        # (missing baseline / rev-list fault) must never collapse into either
        # outcome — with per-task commits the clean tree is the mainline end
        # state, so a stale baseline would misrecord real work as artifact-only.
        baseline_sha="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
        verdict="$(zero_diff_classify "$DEVAGENT_GIT" "$work_dir" HEAD "$baseline_sha")"
        case "$verdict" in
            commits)
                # #116: per-task commits during implement are the norm — a clean
                # tree with commits ahead of baseline means the work is already
                # committed. Full success, not a skip.
                info "work already committed on the branch — nothing further to commit (#116)"
                finish_step "no-op: work already committed per-task (#116)${NOTE:+ — $NOTE}"
                exit 0
                ;;
            empty)
                info "clean tree, no commits — auto-marking step 10 [-] (artifact-only)"
                checklist_mark "$issue_dir/checklist.md" 10 -
                log_append "$issue_dir" commit "auto-skipped: clean tree, no commits (artifact-only issue)"
                exit 0
                ;;
            *)
                die "cannot classify commits-ahead (verdict: ${verdict:-unknown}, baseline_sha: '${baseline_sha:-unset}') — refusing to guess between no-op success and artifact-only skip. Recover the baseline (e.g. 'git -C $work_dir merge-base <default_baseline> HEAD') and set it in the state file, then re-run (#116)."
                ;;
        esac
    fi
fi

type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
[ -r "$type_file" ]  || die "missing $type_file"
[ -r "$title_file" ] || die "missing $title_file"
issue_type="$(tr -d '\n' < "$type_file")"
title="$(tr -d '\n' < "$title_file")"

# Prefix lookup (same map as branch.sh).
prefix="$(config_get_project_field "$project" "branch_prefix_map.$issue_type" 2>/dev/null || true)"
[ -n "$prefix" ] || prefix="$issue_type"

template="$(artifact_resolve "$project" commit_template)" \
    || die "commit_template not resolvable"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
# Substitute placeholders via Python to avoid sed's & / | / \ pitfalls in
# operator-supplied strings (title and NOTE in particular). Plain string
# replace, no regex semantics on the replacement values.
# Placeholder reference: see templates/commit_template.md header comment.
# NB: {{issue}} = directory name (e.g. "Issue-Fork-62"), not bare number.
DEVAGENT_TYPE="$prefix" DEVAGENT_TITLE="$title" \
DEVAGENT_ISSUE="$issue_arg" DEVAGENT_NOTE="${NOTE:-}" \
python3 - "$template" "$body" <<'PY'
import os, re, sys
src, dst = sys.argv[1:]
data = open(src).read()
# Strip HTML comment blocks: template authoring notes (placeholder docs,
# conventions pointers) must not leak into the commit message. git's -F
# cleanup strips '#' lines but not '<!-- -->'.
data = re.sub(r'<!--.*?-->\n?', '', data, flags=re.DOTALL)
data = data.replace("{{type}}",  os.environ.get("DEVAGENT_TYPE",  ""))
data = data.replace("{{title}}", os.environ.get("DEVAGENT_TITLE", ""))
data = data.replace("{{issue}}", os.environ.get("DEVAGENT_ISSUE", ""))
data = data.replace("{{note}}",  os.environ.get("DEVAGENT_NOTE",  ""))
open(dst, "w").write(data.lstrip("\n"))
PY

# Strip any "(1M context)" patterns (case-insensitive BRE; literal parens).
# Trim trailing whitespace on each line.
sed -i 's/[[:space:]]*(1M context)//gI; s/[[:space:]]\{1,\}$//' "$body"

# include_coauthor strip-guard (issue #31): on opt-out projects remove any
# Co-Authored-By trailer the model/template emitted. Default-true guard — an
# unset key must NOT abort under `set -e` (config_get_project_field exits 1).
include_coauthor="$(config_get_project_field "$project" include_coauthor 2>/dev/null || echo true)"
if [ "$include_coauthor" = "false" ]; then
    strip_coauthor "$body"
fi

# work_dir was resolved by the zero-diff guard above; reuse it.
cd "$work_dir"
"$DEVAGENT_GIT" commit -s -F "$body"

finish_step "committed $("$DEVAGENT_GIT" rev-parse --short HEAD)${NOTE:+ — $NOTE}"
