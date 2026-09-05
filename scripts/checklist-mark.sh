#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

by_name=0
if [[ "${1:-}" == "--by-name" ]]; then by_name=1; shift; fi

[[ $# -eq 3 || ( $# -eq 4 && $by_name -eq 0 ) ]] || {
  echo "usage: checklist-mark.sh [--by-name] <issue-dir> <step-num|step-name> <glyph> [expected-name]" >&2
  exit 2
}
issue_dir="$1"; step="$2"; glyph="$3"; expect_name="${4:-}"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
if (( by_name == 1 )); then
  # #558: name-keyed marking survives a checklist carrying two numbering schemes.
  # #589 made checklist_mark_by_name itself fail-closed on an absent name; this
  # pre-probe is KEPT as the CLI's own, user-shaped refusal (it names the wrapper
  # and the file, not a library function). It shares the library's resolver
  # (checklist_step_state_by_name), so probe and writer cannot disagree about
  # whether the name exists.
  checklist_step_state_by_name "$file" "$step" >/dev/null \
    || die "checklist-mark: no step named '$step' in $file"
  checklist_mark_by_name "$file" "$step" "$glyph"
else
  # r3 m3: the optional expected-name arms checklist_mark's wrong-row guard
  # from the CLI — a numeric mark whose row carries a different name (the
  # pre-#558-checklist shape) fails loud instead of flipping another step.
  checklist_mark "$file" "$step" "$glyph" "$expect_name"
fi
echo "step $step → [$glyph]"
