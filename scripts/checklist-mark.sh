#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

by_name=0
if [[ "${1:-}" == "--by-name" ]]; then by_name=1; shift; fi

[[ $# -eq 3 ]] || {
  echo "usage: checklist-mark.sh [--by-name] <issue-dir> <step-num|step-name> <glyph>" >&2
  exit 2
}
issue_dir="$1"; step="$2"; glyph="$3"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
if (( by_name == 1 )); then
  # #558: name-keyed marking is immune to the mixed-numbering aliasing a revision
  # block appended after the renumber creates (old-scheme Revision 1 + new-scheme
  # Revision 2 in one file: number 1 means draft in one block, research in the
  # other). checklist_mark_by_name is no-op-safe on an absent name, so verify
  # existence first (Issue-72: a silent no-op on a load-bearing write hides the miss).
  checklist_step_state_by_name "$file" "$step" >/dev/null \
    || die "checklist-mark: no step named '$step' in $file"
  checklist_mark_by_name "$file" "$step" "$glyph"
else
  checklist_mark "$file" "$step" "$glyph"
fi
echo "step $step → [$glyph]"
