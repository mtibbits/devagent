#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

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

# Find the step currently marked [!]
target=""
for ((i = 0; i <= 20; i++)); do
  st="$(checklist_step_state "$file" "$i" 2>/dev/null || true)"
  if [[ "$st" == '!' ]]; then
    target="$i"
    break
  fi
done
[[ -n "$target" ]] || die "no step is currently [!] in $file"

name="$(checklist_step_name "$file" "$target")"
checklist_mark "$file" "$target" "$new"
rm -f "$issue_dir/STUCK"
log_append "$issue_dir" "$name" "UNSTUCK (now [$new])"
echo "step $target ($name) cleared → [$new]"
