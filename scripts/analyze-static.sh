#!/usr/bin/env bash
# scripts/analyze-static.sh — thin wrapper around static_analysis_diff.py.
# Writes timestamped output under <issue-dir>/analysis/.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_PYTHON:=python3}"

project="${1:-}"
[ -n "$project" ] || die "analyze-static.sh: project required"
config_is_project "$project" || die "analyze-static.sh: unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue (the scan tier
    # can adopt a parked issue's checklist) — pin/state only, else die.
    # (stderr NOT suppressed: an invalid pin must die loudly here, F6.)
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "analyze-static.sh: no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "analyze-static.sh: issue_dir not set or missing"

baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
[ -n "$baseline" ] || baseline="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
[ -n "$baseline" ] || die "analyze-static.sh: no baseline_sha in state and no default_baseline in config"

source_dir="$(config_get_project_field "$project" source_dir)"
build_dir="$(config_get_project_field "$project" build_dir 2>/dev/null || true)"
[ -n "$build_dir" ] || build_dir="$source_dir/build"

# #275: ensure the analyze build dir carries a test-inclusive compile database so
# the static analyzers actually see test-only TUs. Reconfigure in place (idempotent,
# fast) with two benign additive flags. Guard on CMakeLists.txt so non-CMake projects
# (e.g. devagent itself) skip cleanly. Non-fatal: a configure failure degrades to the
# py's existing "compile_commands.json not found" handling rather than aborting analyze.
: "${DEVAGENT_CMAKE:=cmake}"
if [ -f "$source_dir/CMakeLists.txt" ]; then
    if ! "$DEVAGENT_CMAKE" -S "$source_dir" -B "$build_dir" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DENABLE_TESTING=ON >/dev/null; then
        echo "warning: analyze-static.sh: cmake configure of $build_dir failed; compile_commands.json may be stale/absent and static analysis incomplete or vacuous — verify the build dir's generator/source matches" >&2
    fi
fi

mkdir -p "$issue_dir/analysis"
out="$issue_dir/analysis/$(date +%Y-%m-%d)-static.txt"

"$DEVAGENT_PYTHON" "$DEVAGENT_ROOT/static_analysis_diff.py" --repo "$source_dir" "$baseline" "$build_dir" \
    | tee "$out"
