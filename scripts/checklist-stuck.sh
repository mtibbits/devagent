#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"

# --step <N> <name> (#782): mark row N instead of the current step. Kept for operators;
# scripts use --name (#885). <name> is checklist_mark's #558 row guard: a row N that is
# not <name> dies unmarked.
# --name <step-name> (#885): mark the row NAMED <step-name> instead of the current step,
# wherever the template numbers it — mergetoall's CI gate and mergemr's stops mark their
# own row while an earlier row may still be the first unchecked one. An absent name dies,
# checklist untouched.
step="" step_name="" by_name=""
if [[ "${1:-}" == --step ]]; then
  [[ "${2:-}" =~ ^[0-9]+$ && -n "${3:-}" ]] \
    || { echo "checklist-stuck.sh: --step needs a step number and name" >&2; exit 2; }
  step="$2"; step_name="$3"; shift 3
elif [[ "${1:-}" == --name ]]; then
  [[ -n "${2:-}" ]] \
    || { echo "checklist-stuck.sh: --name needs a step name" >&2; exit 2; }
  by_name="$2"; shift 2
fi
[[ $# -ge 2 ]] || {
  echo "usage: checklist-stuck.sh [--step <N> <name> | --name <step-name>] <issue-dir> <reason...>" >&2
  exit 2
}
issue_dir="$1"; shift
reason="$*"
file="$issue_dir/checklist.md"
[[ -f "$file" ]] || die "no checklist at $file"
trust_entry_check_devdoc "checklist-stuck" "$(dirname -- "$issue_dir")"
quarantine_guard_dir "checklist-stuck" "$issue_dir"

if [[ -n "$by_name" ]]; then
  cur="$(checklist_step_num_by_name "$file" "$by_name")" \
    || die "no step named '$by_name' in $file"
elif [[ -n "$step" ]]; then
  cur="$step"
else
  cur="$(checklist_current_step "$file")"
  [[ "$cur" != "done" ]] || die "checklist is already complete; nothing to mark stuck"
fi
if [[ -n "$by_name" ]]; then
  name="$by_name"
else
  name="$(checklist_step_name "$file" "$cur")" || die "no step $cur in $file"
fi

last_good="$(stuck_last_good "$file" "$cur")" \
  || die "could not read the last good step before $cur in $file"

if [[ -n "$by_name" ]]; then
  checklist_mark_by_name "$file" "$by_name" '!'
else
  checklist_mark "$file" "$cur" '!' "$step_name"
fi

stuck_write "$issue_dir" "$cur" "$name" "$reason" "$last_good" \
  || die "could not write $issue_dir/STUCK"

log_append "$issue_dir" "$name" "STUCK: $reason"
echo "marked step $cur ($name) [!] and wrote $issue_dir/STUCK"
