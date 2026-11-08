#!/usr/bin/env bash
# scripts/archive-transcripts.sh — copy this machine's Claude Code transcripts into the
# durable archive configured by [archive] in config.toml (#731).
#   archive-transcripts.sh [--if-configured]   archive (cleanup, step 24, passes the flag)
#   archive-transcripts.sh --doctor            doctor's warnings as <label>TAB<detail>; writes nothing
# Exit 0 archived (or --if-configured with no [archive].transcripts_dir); 1 a file failed or
# another run holds the lock (no last-run stamp); 2 refused or usage (nothing written).
# Layout, refusals and counts: the docstring of lib/archive-transcripts.py.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/archive-transcripts.py" "$@"
