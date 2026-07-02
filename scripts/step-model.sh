#!/usr/bin/env bash
# scripts/step-model.sh — CLI face of step_models_tier (#150 table, #151 consumer).
#   step-model.sh <project> <step-num>
# Echoes the configured tier (exit 0) or prints nothing and exits 1 when no
# tier resolves — callers treat empty as "no override; inherit session model".
# Read-only. Used by checking-class skills (improve 3, review 13, redmr 14)
# to resolve the subagent dispatch model override. The advisory surfacing in
# next.sh/catchup.sh is unchanged.
set -euo pipefail
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
step_models_tier "${1:?usage: step-model.sh <project> <step-num>}" "${2:?usage: step-model.sh <project> <step-num>}"
