#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

[[ $# -eq 3 ]] || {
  echo "usage: checklist-mark.sh <issue-dir> <step-num> <glyph>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; glyph="$3"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
checklist_mark "$file" "$step" "$glyph"
echo "step $step → [$glyph]"
