#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

# --step <N> (#782): mark row N instead of the current step — mergetoall's CI gate
# marks its own row 19 while an earlier row may still be the first unchecked one.
step=""
if [[ "${1:-}" == --step ]]; then
  [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "checklist-stuck.sh: --step needs a step number" >&2; exit 2; }
  step="$2"; shift 2
fi
[[ $# -ge 2 ]] || {
  echo "usage: checklist-stuck.sh [--step <N>] <issue-dir> <reason...>" >&2
  exit 2
}
issue_dir="$1"; shift
reason="$*"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"

if [[ -n "$step" ]]; then
  cur="$step"
else
  cur="$(checklist_current_step "$file")"
  [[ "$cur" != "done" ]] || die "checklist is already complete; nothing to mark stuck"
fi
name="$(checklist_step_name "$file" "$cur")" || die "no step $cur in $file"

# Find last good step number for the STUCK file.
last_good=""
for ((i = cur - 1; i >= 0; i--)); do
  st="$(checklist_step_state "$file" "$i" 2>/dev/null || true)"
  if [[ "$st" == "x" ]]; then
    last_good="$i $(checklist_step_name "$file" "$i")"
    break
  fi
done

checklist_mark "$file" "$cur" '!'

cat > "$issue_dir/STUCK" <<EOF
Step:        $cur $name
Reason:      $reason
Last good:   ${last_good:-(none)}
Created:     $(date -Iseconds)
EOF

log_append "$issue_dir" "$name" "STUCK: $reason"
echo "marked step $cur ($name) [!] and wrote $issue_dir/STUCK"
