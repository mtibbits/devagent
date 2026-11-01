#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"

[[ $# -ge 3 ]] || {
  echo "usage: checklist-log.sh <issue-dir> <step-name> <message...>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; shift 2
trust_entry_check_devdoc "checklist-log" "$(dirname -- "$issue_dir")"
log_append "$issue_dir" "$step" "$*"
