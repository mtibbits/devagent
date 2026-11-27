#!/usr/bin/env bash
# scripts/plan-estimate.sh — the plan's structured estimate, read-only (#738;
# lib/plan-estimate.py; spec §13.7). Reads the `- Estimate (scope|confirmed):
# {est: …, tok: …}` lines under a plan's `### Size estimate` heading.
#   plan-estimate.sh [--json | --impact-line] <imPlan.md>
# --json (the default) prints the result as one JSON object; --impact-line
# prints the impact step's `- Estimate vs actual (interim): …` line, with the
# `<agent wall>` and `<cost>` slots the impact step fills from its Workflow lines.
# It takes one path and resolves no project, issue or state.
# Exit: 0 present, 1 absent (no structured estimate), 3 unreadable (an
# estimate-shaped line that does not parse) — each prints one line on stdout and
# nothing on stderr; 2 usage error or unreadable file (stdout empty); 4 internal
# error (stdout empty).
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/plan-estimate.py" "$@"
