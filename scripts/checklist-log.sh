#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

[[ $# -ge 3 ]] || {
  echo "usage: checklist-log.sh <issue-dir> <step-name> <message...>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; shift 2
log_append "$issue_dir" "$step" "$*"
