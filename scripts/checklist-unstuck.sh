#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

usage() {
  echo "usage: checklist-unstuck.sh (--pending|--in-progress) <issue-dir>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
case "$1" in
  --pending)     new=' ' ;;
  --in-progress) new='~' ;;
  *) usage ;;
esac
issue_dir="$2"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
[[ -f "$issue_dir/STUCK" ]] || die "no STUCK file at $issue_dir/STUCK"

# #587: the row-selection scan and the by-line mark live in
# scripts/lib/checklist.sh (see checklist_find_glyph_line's header), shared with
# unstuck.sh and resume.sh so the three sites cannot drift again (#82).
# Semantics unchanged from this file's #558 shape: active-block [!] wins, older
# block is the legacy file-wide fallback (#76), mark targets the found LINE.
found="$(checklist_find_glyph_line "$file" '!')"
[[ -n "$found" ]] || die "no step is currently [!] in $file"
row="${found%%:*}"; target="${found#*:}"

name="$(checklist_step_name_at_line "$file" "$row")"   || die "cannot read the step name at line $row of $file"
checklist_mark_line "$file" "$row" "$new"
rm -f "$issue_dir/STUCK"
log_append "$issue_dir" "$name" "UNSTUCK (now [$new])"
echo "step $target ($name) cleared → [$new]"
