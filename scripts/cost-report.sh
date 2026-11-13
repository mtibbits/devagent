#!/usr/bin/env bash
# scripts/cost-report.sh — token cost per (project, issue) and per workflow step,
# read from this machine's Claude Code session transcripts (every dir with
# --project, --all-dirs or --overhead; else this directory's) and, with
# --archive, from a scripts/archive-transcripts.sh archive (.jsonl.gz, every
# host partition). --transcripts overrides the every-dir read.
#   cost-report.sh [--project P] [--issue Issue-N] [--summary | --json] [--all-dirs]
#                  [--transcripts <dir>]... [--archive <dir>] [--overhead]
#                  [--time [--idle-gap MIN] [--tool-gap MIN] [--attention-cap MIN]]
# --archive alone reads only the archive; --all-dirs, --project, --overhead or
# --transcripts add the live dirs. One API call is counted once across every
# file read.
# --json prints one JSON object per (project, issue) with its transcript sources.
# --time adds a time line per pair: agent wall time (the headline: the union of
# busy intervals), agent busy time (their sum over parallel transcripts) and
# operator time with its event counts. A tool wait counts up to --tool-gap
# (default 60), any other interval up to --idle-gap (5), all or nothing; an
# operator event adds its latency up to --attention-cap (15), else counts a
# return after absence. The rule line echoes the three values.
# --overhead reports the (no project)/(no issue) calls as per-project overhead,
# each call placed by the first rule that applies: (1) hint — the most recent
# earlier typed /devagent:<cmd> naming a known project and no issue, or Bash
# DEVAGENT_PROJECT=<known project>, in the same session (a hint never changes a
# pair, and lasts until the next hint); (2) cwd — the record's cwd lies under a
# project's source_dir, worktree_root (default <source_dir>-wt) or devdoc_dir,
# longest match, per the spec's path-containment rule; (3) else
# (unassigned) <cwd>. Lines: `<project>/(overhead): <summary>; hint N, cwd N`
# (calls each rule placed), then `(unassigned) <cwd>: <summary>`. Calls and
# totals add up to the (no project)/(no issue) line; session counts can
# overlap across lines. --overhead reads every dir and refuses --issue and
# --time; --project P prints only P's line.
# The impact step (22) records `--project <project> --issue <Issue-N> --summary --time`
# in impact.md, so a workflow change can be judged against what an issue
# actually cost.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cost-report.py" "$@"
