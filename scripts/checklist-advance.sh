#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"

[[ $# -eq 1 ]] || { echo "usage: checklist-advance.sh <issue-dir>" >&2; exit 2; }
issue_dir="$1"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
trust_entry_check_devdoc "checklist-advance" "$(dirname -- "$issue_dir")"

new="$(checklist_advance "$file")"
if [[ "$new" == "done" ]]; then
  echo "all steps complete"
else
  echo "now at step $new"
fi
