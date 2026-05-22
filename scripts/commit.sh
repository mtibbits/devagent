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

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "commit.sh: project required"
config_is_project "$project" || die "commit.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"
[ -n "$issue_arg" ] || die "commit.sh: no active issue and no issue arg"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "commit.sh: issue dir not found: $issue_dir"

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
DEVAGENT_TYPE="$prefix" DEVAGENT_TITLE="$title" \
DEVAGENT_ISSUE="$issue_arg" DEVAGENT_NOTE="${NOTE:-}" \
python3 - "$template" "$body" <<'PY'
import os, sys
src, dst = sys.argv[1:]
data = open(src).read()
data = data.replace("{{type}}",  os.environ.get("DEVAGENT_TYPE",  ""))
data = data.replace("{{title}}", os.environ.get("DEVAGENT_TITLE", ""))
data = data.replace("{{issue}}", os.environ.get("DEVAGENT_ISSUE", ""))
data = data.replace("{{note}}",  os.environ.get("DEVAGENT_NOTE",  ""))
open(dst, "w").write(data)
PY

# Strip any "(1M context)" patterns (case-insensitive BRE; literal parens).
# Trim trailing whitespace on each line.
sed -i 's/[[:space:]]*(1M context)//gI; s/[[:space:]]\{1,\}$//' "$body"

source_dir="$(config_get_project_field "$project" source_dir)"
worktree="$(state_get "$project" worktree_path 2>/dev/null || true)"
work_dir="${worktree:-$source_dir}"

cd "$work_dir"
"$DEVAGENT_GIT" commit -s -F "$body"

state_set "$project" last_step      "10"
state_set "$project" last_step_name "commit"
checklist_mark "$issue_dir/checklist.md" 10 x
log_append "$issue_dir" commit "committed $("$DEVAGENT_GIT" rev-parse --short HEAD)${NOTE:+ — $NOTE}"
