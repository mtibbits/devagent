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

# Find the step currently marked [!]. Candidates come from the checklist's
# own rows — no numeric bound to keep in step with the templates (#558 r2:
# the 0..21 loop could not unstick 22/23 and reported a FALSE "no step is
# currently [!]"). A [!] in the active revision block wins; a [!] only in an
# older block is the legacy file-wide fallback (#76).
target="$(awk '
  /^## Revision / { blk = NR }
  match($0, /^- \[!\][ \t]+[0-9]+\./) {
    num = substr($0, RSTART, RLENGTH)
    sub(/^- \[!\][ \t]+/, "", num); sub(/\.$/, "", num)
    rows[++n] = NR ":" (num + 0)
  }
  END {
    for (i = 1; i <= n; i++) {
      split(rows[i], a, ":")
      if (a[1] > blk) { print a[2]; exit }
    }
    if (n) { split(rows[1], a, ":"); print a[2] }
  }
' "$file")"
[[ -n "$target" ]] || die "no step is currently [!] in $file"

name="$(checklist_step_name "$file" "$target")"
checklist_mark "$file" "$target" "$new"
rm -f "$issue_dir/STUCK"
log_append "$issue_dir" "$name" "UNSTUCK (now [$new])"
echo "step $target ($name) cleared → [$new]"
