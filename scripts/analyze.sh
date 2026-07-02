#!/usr/bin/env bash
# scripts/analyze.sh — step 11. Sequences static then sanitizers per spec §6.3.
# No sub-step tracking in the checklist (spec §18).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_ANALYZE_STATIC:=$DEVAGENT_ROOT/scripts/analyze-static.sh}"
: "${DEVAGENT_ANALYZE_SANITIZERS:=$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh}"

project="${1:-}"
[ -n "$project" ] || die "analyze.sh: project required"
config_is_project "$project" || die "analyze.sh: unknown project '$project'"

issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue 2>/dev/null || true)"

issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "analyze.sh: issue_dir not set or missing"

"$DEVAGENT_ANALYZE_STATIC"     "$project" "$issue_arg"
"$DEVAGENT_ANALYZE_SANITIZERS" "$project" "$issue_arg"

state_set_many "$project" str last_step "11" str last_step_name "analyze"
checklist_mark "$issue_dir/checklist.md" 11 x
log_append "$issue_dir" analyze "static + sanitizers complete${NOTE:+ — $NOTE}"
checklist_print_next_hint "$issue_dir/checklist.md"
