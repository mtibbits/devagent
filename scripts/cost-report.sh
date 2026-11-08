#!/usr/bin/env bash
# scripts/cost-report.sh — token cost per (project, issue) and per workflow step,
# read from this machine's Claude Code session transcripts (every dir with
# --project or --all-dirs; else this directory's) and, with --archive, from a
# scripts/archive-transcripts.sh archive (.jsonl.gz, every host partition).
#   cost-report.sh [--project P] [--issue Issue-N] [--summary | --json] [--all-dirs]
#                  [--transcripts <dir>]... [--archive <dir>]
#                  [--time [--idle-gap MIN] [--tool-gap MIN] [--attention-cap MIN]]
# --archive alone reads only the archive; --all-dirs, --project or --transcripts
# add the live dirs. One API call is counted once across every file read.
# --json prints one JSON object per (project, issue) with its transcript sources.
# --time adds a time line per pair: agent wall time (the headline: the union of
# busy intervals), agent busy time (their sum over parallel transcripts) and
# operator time with its event counts. A tool wait counts up to --tool-gap
# (default 60), any other interval up to --idle-gap (5), all or nothing; an
# operator event adds its latency up to --attention-cap (15), else counts a
# return after absence. The rule line echoes the three values.
# The impact step (22) records `--project <project> --issue <Issue-N> --summary --time`
# in impact.md, so a workflow change can be judged against what an issue
# actually cost.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cost-report.py" "$@"
