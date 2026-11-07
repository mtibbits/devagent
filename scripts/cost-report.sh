#!/usr/bin/env bash
# scripts/cost-report.sh — token cost per (project, issue) and per workflow step,
# read from this machine's Claude Code session transcripts (every dir with
# --project or --all-dirs; else this directory's).
#   cost-report.sh [--project P] [--issue Issue-N] [--summary] [--all-dirs] [--transcripts <dir>]...
# The impact step (22) records `--project <project> --issue <Issue-N> --summary`
# in impact.md, so a workflow change can be judged against what an issue
# actually cost.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cost-report.py" "$@"
