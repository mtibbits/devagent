#!/usr/bin/env bash
# scripts/analyze-static.sh — thin wrapper around static_analysis_diff.py.
# Writes timestamped output under <issue-dir>/analysis/.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$DEVAGENT_ROOT/scripts/lib/quarantine.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=lib/watchdog-limits.sh
. "$DEVAGENT_ROOT/scripts/lib/watchdog-limits.sh"

: "${DEVAGENT_PYTHON:=python3}"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"
quarantine_guard_marker "analyze-static" "$project" "${2:-}"

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

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"

baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
[ -n "$baseline" ] || baseline="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
[ -n "$baseline" ] || die "no baseline_sha in state and no default_baseline in config"

source_dir="$(config_get_project_field "$project" source_dir)"
build_dir="$(config_get_project_field "$project" build_dir 2>/dev/null || true)"
# #351: key the FALLBACK build dir per project+issue so two concurrent chains
# sharing a source_dir don't interleave in the same dir. An explicitly-configured
# build_dir is the operator's choice and is respected as-is.
[ -n "$build_dir" ] || build_dir="$source_dir/build-$(printf '%s-%s' "$project" "$issue_arg" | tr -c 'A-Za-z0-9' '-')"

# #351: bound the reconfigure below (a wedged cmake would hang an --auto chain).
timeout_budget="${DEVAGENT_ANALYZE_TIMEOUT:-$(config_get_project_field "$project" analyze_timeout 2>/dev/null || true)}"
: "${timeout_budget:=1800}"

# #932: every leg below runs under libexec/long-run.sh, so that its output is the
# session's progress, and declares one silent window, resolved here, ONCE, before
# any leg: analyze_silent_secs, or min(the budget above, watchdog_silent_max_secs)
# when that key is unset (a leg the budget allows is then never read as stalled
# at the shipped limits). A window set above the maximum fails the step before
# anything runs (doctor fails the same config); one that cannot be read warns
# once and the derived window stands in. Attended runs take the same path: the
# wrapper then writes its log and nothing else. --project goes in only for a
# name the wrapper's grammar takes; any other project runs without it.
_silent_rc=0
watchdog_analyze_window "$project" "$timeout_budget" || _silent_rc=$?
[ "$_silent_rc" -eq 0 ] || die "analyze-static: $WATCHDOG_ANALYZE_NOTE. No leg was run."
[ -z "$WATCHDOG_ANALYZE_NOTE" ] || warn "analyze-static: $WATCHDOG_ANALYZE_NOTE"
long_run=(bash "$DEVAGENT_ROOT/libexec/long-run.sh" --silent "${WATCHDOG_ANALYZE_SECS}s")
[[ ! "$project" =~ ^[A-Za-z0-9_-]+$ ]] || long_run+=(--project "$project")

# #275: ensure the analyze build dir carries a test-inclusive compile database so
# the static analyzers actually see test-only TUs. Reconfigure in place (idempotent,
# fast) with two benign additive flags. Guard on CMakeLists.txt so non-CMake projects
# (e.g. devagent itself) skip cleanly. Non-fatal: a configure failure degrades to the
# py's existing "compile_commands.json not found" handling rather than aborting analyze.
: "${DEVAGENT_CMAKE:=cmake}"
if [ -f "$source_dir/CMakeLists.txt" ]; then
    # #932: two streams, as before: stdout to /dev/null, stderr to the caller.
    if ! "${long_run[@]}" -- \
            timeout -k 10 "$timeout_budget" "$DEVAGENT_CMAKE" -S "$source_dir" -B "$build_dir" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DENABLE_TESTING=ON >/dev/null; then
        echo "warning: analyze-static.sh: cmake configure of $build_dir failed; compile_commands.json may be stale/absent and static analysis incomplete or vacuous — verify the build dir's generator/source matches" >&2
    fi
fi

mkdir -p "$issue_dir/analysis"
out="$issue_dir/analysis/$(date_tag)-static.txt"

# #932: two streams, as before: the analyzer's stdout is the artifact, and its
# progress lines stay on stderr, where they are written flushed.
# PYTHONUNBUFFERED=1 (the wrapper runs a leading NAME=value through env) makes
# its stdout reach the pipe as it is written rather than at exit. The analyzer
# captures its children's output, so a phase is silent until it ends: that is
# what the window above is for (Issue-932 R2-U2: this leg's cadence is unmeasured).
"${long_run[@]}" -- \
    PYTHONUNBUFFERED=1 "$DEVAGENT_PYTHON" "$DEVAGENT_ROOT/static_analysis_diff.py" --repo "$source_dir" "$baseline" "$build_dir" \
    | tee "$out"
