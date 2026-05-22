#!/usr/bin/env bash
# scripts/analyze-static.sh — thin wrapper around static_analysis_diff.py.
# Writes timestamped output under <issue-dir>/analysis/.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"

: "${DEVAGENT_PYTHON:=python3}"

project="${1:-}"
[ -n "$project" ] || die "analyze-static.sh: project required"
config_is_project "$project" || die "analyze-static.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "analyze-static.sh: issue_dir not set or missing"

baseline="$(state_get "$project" baseline_sha 2>/dev/null || true)"
[ -n "$baseline" ] || baseline="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
[ -n "$baseline" ] || die "analyze-static.sh: no baseline_sha in state and no default_baseline in config"

build_dir="$(config_get_project_field "$project" build_dir 2>/dev/null || true)"
if [ -z "$build_dir" ]; then
    source_dir="$(config_get_project_field "$project" source_dir)"
    build_dir="$source_dir/build"
fi

mkdir -p "$issue_dir/analysis"
out="$issue_dir/analysis/$(date +%Y-%m-%d)-static.txt"

"$DEVAGENT_PYTHON" "$DEVAGENT_ROOT/static_analysis_diff.py" "$baseline" "$build_dir" \
    | tee "$out"
