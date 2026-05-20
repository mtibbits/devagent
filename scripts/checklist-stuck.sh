#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"

[[ $# -ge 2 ]] || {
  echo "usage: checklist-stuck.sh <issue-dir> <reason...>" >&2
  exit 2
}
issue_dir="$1"; shift
reason="$*"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"

cur="$(checklist_current_step "$file")"
[[ "$cur" != "done" ]] || die "checklist is already complete; nothing to mark stuck"
name="$(checklist_step_name "$file" "$cur")"

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
