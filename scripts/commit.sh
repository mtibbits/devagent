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
# shellcheck source=lib/checklist.sh
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
# shellcheck source=lib/log.sh
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
# shellcheck source=lib/artifact.sh
. "$DEVAGENT_ROOT/scripts/lib/artifact.sh"
# shellcheck source=lib/coauthor.sh
. "$DEVAGENT_ROOT/scripts/lib/coauthor.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "commit.sh: project required"
config_is_project "$project" || die "commit.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
[ -n "$issue_arg" ] || die "commit.sh: no active issue and no issue arg"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "commit.sh: issue dir not found: $issue_dir"

# Zero-diff guard — decided on the WORKING TREE, not commits-ahead (issue #25).
# commit.sh commits the staged index (`git commit -s -F` below), and the
# implement step leaves work in the working tree (staged or not), so "no
# commits ahead of baseline" does NOT mean "no work". Three cases:
#   staged changes present     -> fall through and commit them (normal path)
#   dirty but nothing staged   -> fail loudly; never silently skip real work
#   clean tree AND no commits  -> genuine artifact-only, auto-mark [-] and exit
baseline_sha="$(state_get "$project" baseline_sha 2>/dev/null || true)"
source_dir="$(config_get_project_field "$project" source_dir)"
worktree="$(state_get "$project" worktree_path 2>/dev/null || true)"
work_dir="${worktree:-$source_dir}"

has_commits=""
if [ -n "$baseline_sha" ]; then
    has_commits="$("$DEVAGENT_GIT" -C "$work_dir" rev-list HEAD "^$baseline_sha" 2>/dev/null || true)"
fi
staged=""
# Fail-safe by direction: any git fault here (e.g. not-a-repo, exit >=2) takes
# the `|| staged=1` branch, so the guard falls through to `git commit` below
# which fails loudly — never a silent skip. `dirty`'s `|| true` masks the same
# fault to "", but staged=1 has already won, so it can't re-introduce the skip.
"$DEVAGENT_GIT" -C "$work_dir" diff --cached --quiet 2>/dev/null || staged=1
dirty="$("$DEVAGENT_GIT" -C "$work_dir" status --porcelain 2>/dev/null || true)"

if [ -z "$has_commits" ] && [ -z "$staged" ]; then
    if [ -n "$dirty" ]; then
        die "commit.sh: working tree has uncommitted changes but nothing is staged — stage your in-scope files ('git add ...') then re-run. Refusing to silently skip the commit step (would ship an empty PR; see issue #25)."
    fi
    info "commit.sh: clean tree, no commits — auto-marking step 10 [-] (artifact-only)"
    checklist_mark "$issue_dir/checklist.md" 10 -
    log_append "$issue_dir" commit "auto-skipped: clean tree, no commits (artifact-only issue)"
    exit 0
fi

type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
[ -r "$type_file" ]  || die "commit.sh: missing $type_file"
[ -r "$title_file" ] || die "commit.sh: missing $title_file"
issue_type="$(tr -d '\n' < "$type_file")"
title="$(tr -d '\n' < "$title_file")"

# Prefix lookup (same map as branch.sh).
prefix="$(config_get_project_field "$project" "branch_prefix_map.$issue_type" 2>/dev/null || true)"
[ -n "$prefix" ] || prefix="$issue_type"

template="$(artifact_resolve "$project" commit_template)" \
    || die "commit.sh: commit_template not resolvable"

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

state_set "$project" last_step      "10"
state_set "$project" last_step_name "commit"
checklist_mark "$issue_dir/checklist.md" 10 x
log_append "$issue_dir" commit "committed $("$DEVAGENT_GIT" rev-parse --short HEAD)${NOTE:+ — $NOTE}"
checklist_print_next_hint "$issue_dir/checklist.md"
