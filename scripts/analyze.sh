#!/usr/bin/env bash
# scripts/analyze.sh — step 11. Dispatches the project's analyzer family per
# the optional `analyze` config key (#55): cmake (default — static then
# sanitizers per spec §6.3), shellcheck (diff-scoped bash analysis), or none
# (self-marks the step [-] with a logged reason — the acceptance criterion is
# that a non-C project never needs a manual skip).
# No sub-step tracking in the checklist (spec §18).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_ANALYZE_STATIC:=$DEVAGENT_ROOT/scripts/analyze-static.sh}"
: "${DEVAGENT_ANALYZE_SANITIZERS:=$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh}"
: "${DEVAGENT_ANALYZE_SHELLCHECK:=$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh}"

project="${1:-}"
[ -n "$project" ] || die "analyze.sh: project required"
config_is_project "$project" || die "analyze.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(active_resolve_issue "$project" 2>/dev/null || true)"

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "analyze.sh: issue_dir not set or missing"

# #55: analyzer family. Absent or explicitly empty ⇒ cmake (byte-compatible
# with pre-knob behavior); anything else unknown dies before any analyzer,
# state write, or checklist mark.
mode="$(config_get_project_field "$project" analyze 2>/dev/null || true)"
[ -n "$mode" ] || mode="cmake"

case "$mode" in
cmake)
    "$DEVAGENT_ANALYZE_STATIC"     "$project" "$issue_arg"
    "$DEVAGENT_ANALYZE_SANITIZERS" "$project" "$issue_arg"
    log_line="static + sanitizers complete"
    ;;
shellcheck)
    "$DEVAGENT_ANALYZE_SHELLCHECK" "$project" "$issue_arg"
    log_line="shellcheck (diff-scoped) complete; sanitizers skipped: none exist for bash (bats suite is the dynamic coverage)"
    ;;
none)
    state_ctx_set_many "$project" "$issue_arg" str last_step "11" str last_step_name "analyze"
    checklist_mark "$issue_dir/checklist.md" 11 -
    log_append "$issue_dir" analyze "skipped: analyze = \"none\" for project '$project' — no analyzer family applies${NOTE:+ — $NOTE}"
    checklist_print_next_hint "$issue_dir/checklist.md"
    exit 0
    ;;
*)
    die "analyze.sh: unknown analyze value '$mode' for project '$project' (legal: cmake | shellcheck | none)"
    ;;
esac

state_ctx_set_many "$project" "$issue_arg" str last_step "11" str last_step_name "analyze"
checklist_mark "$issue_dir/checklist.md" 11 x
log_append "$issue_dir" analyze "${log_line}${NOTE:+ — $NOTE}"
checklist_print_next_hint "$issue_dir/checklist.md"
