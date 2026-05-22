#!/usr/bin/env bash
# scripts/lib/permission.sh — enforce per-project permission gates (spec §8).
#
# Public: permission_gate <project> <gate-name> [plan-text]
#   * if [project.<name>.permissions].<gate-name> == "true" → return 0 silently
#   * else: print the plan to stderr, call confirm() (which honors $DA_YES=1
#     for non-interactive bypass and returns 1 if non-tty without DA_YES)
#   * on confirm rejection: die "permission_gate: <gate> denied"
#
# Requires paths.sh, io.sh, config.sh sourced first.

permission_gate() {
    local project="$1" gate="$2" plan="${3:-}"
    [[ -n "$project" && -n "$gate" ]] || {
        echo "permission_gate: project+gate required" >&2
        return 2
    }
    local allowed
    allowed="$(config_get_project_field "$project" "permissions.$gate" 2>/dev/null || echo false)"
    if [[ "$allowed" == "true" ]]; then
        return 0
    fi
    [[ -n "$plan" ]] && echo "$plan" >&2
    if confirm "Proceed with $gate?"; then
        return 0
    fi
    die "permission_gate: $gate denied"
}
