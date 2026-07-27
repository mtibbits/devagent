#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
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
# older block is the legacy file-wide fallback (#76). The mark targets the
# found LINE, never the step number: closeout numbers are REUSED across
# revision blocks, and a number-keyed mark re-scopes to the ACTIVE block —
# flipping the wrong block's row while the [!] survives (r3 BLOCKING-2).
found="$(awk '
  /^## Revision / { blk = NR }
  match($0, /^- \[!\][ \t]+[0-9]+\./) {
    num = substr($0, RSTART, RLENGTH)
    sub(/^- \[!\][ \t]+/, "", num); sub(/\.$/, "", num)
    rows[++n] = NR ":" (num + 0)
  }
  END {
    for (i = 1; i <= n; i++) {
      split(rows[i], a, ":")
      if (a[1] > blk) { print rows[i]; exit }
    }
    if (n) print rows[1]
  }
' "$file")"
[[ -n "$found" ]] || die "no step is currently [!] in $file"
row="${found%%:*}"; target="${found#*:}"

name="$(awk -v ln="$row" 'NR == ln {
  sub(/^- \[!\][ \t]+[0-9]+\.[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit
}' "$file")"
[[ -n "$name" ]] || die "cannot read the step name at line $row of $file"
sed -i "${row}s/^- \[!\]/- [$new]/" "$file"
rm -f "$issue_dir/STUCK"
log_append "$issue_dir" "$name" "UNSTUCK (now [$new])"
echo "step $target ($name) cleared → [$new]"
