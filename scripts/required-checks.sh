#!/usr/bin/env bash
# scripts/required-checks.sh — #1097: the CI checks a project requires, for a
# caller that cannot source lib/config.sh (a command wrapper, a skill body).
#   required-checks.sh <project>
# stdout: each `[project.<name>] required_checks` name on its own line, in config
# order; nothing when the project requires none.
#
# Exit codes: 0 = the list, possibly empty · 1 = the list could not be
# determined (an unknown project, a bad required_checks or required_checks_paths
# value, an unreadable config; the reason is on stderr and stdout is empty) ·
# 2 = usage.
# A caller must treat non-zero as "stop and report", never as "no required
# checks" (devagent Issue-713).
# Read-only: it reads config.toml and nothing else.
set -euo pipefail
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "usage: required-checks.sh <project>" >&2
  exit 2
fi
project="$1"
# config_load first: without it a missing or malformed config.toml reads as
# "unknown project", which names the wrong thing to fix.
config_load
config_is_project "$project" || die "unknown project '$project'"

required_checks_resolve "$project"   # setter-globals: called bare; dies on a bad value
if (( ${#REQUIRED_CHECKS[@]} > 0 )); then
  printf '%s\n' "${REQUIRED_CHECKS[@]}"
fi
