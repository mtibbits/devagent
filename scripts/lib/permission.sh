#!/usr/bin/env bash
# scripts/lib/permission.sh — enforce per-project permission gates (spec §8).
#
# Public: permission_gate <project> <gate-name> [plan-text]
#   * if permission_value says "true" → return 0 silently
#   * else, under a trust policy in scope (#713): die
#     "permission_gate: <gate> denied (trust policy)" — no prompt, so no DA_YES
#     and no tty can open a gate the policy closed
#   * else: print the plan to stderr, call confirm() (which honors $DA_YES=1
#     for non-interactive bypass and returns 1 if non-tty without DA_YES)
#   * on confirm rejection: die "permission_gate: <gate> denied"
#
# Public: permission_value <project> <gate-name> → prints true|false. Under a
#   trust policy in scope (TRUST_IN_SCOPE=1, set by trust_entry_check) the
#   policy's value alone; otherwise [project.<name>.permissions].<gate-name>.
#   Every gate read goes through here (tests/trust-gates.bats).
#
# Requires paths.sh, io.sh, config.sh sourced first.

permission_value() {
    local project="$1" gate="$2" v
    if [[ "${TRUST_IN_SCOPE:-0}" == 1 ]]; then
        v="${TRUST_VAL[$gate]:-false}"
    else
        v="$(config_get_project_field "$project" "permissions.$gate" 2>/dev/null || echo false)"
    fi
    if [[ "${v//$'\r'/}" == "true" ]]; then echo true; else echo false; fi
}

permission_gate() {
    local project="$1" gate="$2" plan="${3:-}"
    [[ -n "$project" && -n "$gate" ]] || {
        echo "permission_gate: project+gate required" >&2
        return 2
    }
    if [[ "$(permission_value "$project" "$gate")" == "true" ]]; then
        return 0
    fi
    if [[ "${TRUST_IN_SCOPE:-0}" == 1 ]]; then
        die "permission_gate: $gate denied (trust policy)"
    fi
    [[ -n "$plan" ]] && echo "$plan" >&2
    if confirm "Proceed with $gate?"; then
        return 0
    fi
    die "permission_gate: $gate denied"
}
