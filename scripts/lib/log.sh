#!/usr/bin/env bash
# scripts/lib/log.sh — append/tail log entries in <issue-dir>/checklist.md.
# Requires paths.sh + io.sh sourced.
# Format (spec §5.2):
#   - YYYY-MM-DD HH:MM  <step-name>: <message>

_log_now() {
  date '+%Y-%m-%d %H:%M'
}

log_append() {
  local issue_dir="$1" step="$2" msg="$3"
  local file="$issue_dir/checklist.md"
  [[ -f "$file" ]] || die "log_append: no checklist at $file"
  [[ -n "$step" ]] || die "log_append: step name required"
  [[ -n "$msg"  ]] || die "log_append: message required"
  if [[ "$msg" == *$'\n'* ]]; then
    die "log_append: message must be a single line"
  fi
  if ! grep -q '^## Log' "$file"; then
    die "log_append: '## Log' section missing in $file"
  fi
  local line
  line="- $(_log_now)  ${step}: ${msg}"
  printf '%s\n' "$line" >> "$file"
}

log_tail() {
  local issue_dir="$1" n="${2:-10}"
  local file="$issue_dir/checklist.md"
  [[ -f "$file" ]] || die "log_tail: no checklist at $file"
  awk '/^## Log/{p=1; next} p' "$file" | grep -E '^- [0-9]{4}-' | tail -n "$n"
}
