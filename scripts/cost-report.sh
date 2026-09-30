#!/usr/bin/env bash
# scripts/cost-report.sh — token cost per issue and per workflow step, read from
# this directory's Claude Code session transcripts.
#   cost-report.sh [--issue Issue-N] [--summary] [--transcripts <dir>]...
# The impact step (21) records `--issue <Issue-N> --summary` in impact.md, so a
# workflow change can be judged against what an issue actually cost.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cost-report.py" "$@"
