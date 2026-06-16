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
  local line tmp
  line="- $(_log_now)  ${step}: ${msg}"
  # #75: insert at the END of the `## Log` section (before the next `## `
  # heading, or EOF if Log is last), not at EOF — revise.sh appends
  # `## Revision N` blocks after `## Log`, and the log parsers stop at the next
  # heading, so an EOF append would be lost. Trailing blank lines inside the
  # section are buffered so the new entry sits with the other log lines.
  tmp="$(mktemp)"
  if awk -v line="$line" '
    /^## / {
      if (in_log && !inserted) { print line; inserted = 1 }
      for (i = 1; i <= nb; i++) print blanks[i]
      nb = 0
      print
      in_log = ($0 ~ /^## Log/) ? 1 : 0
      next
    }
    {
      if (in_log && !inserted && $0 ~ /^[[:space:]]*$/) {
        blanks[++nb] = $0
        next
      }
      for (i = 1; i <= nb; i++) print blanks[i]
      nb = 0
      print
    }
    END {
      if (in_log && !inserted) print line
      for (i = 1; i <= nb; i++) print blanks[i]
    }
  ' "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "log_append: failed to update $file (file left intact)"
  fi
}

log_tail() {
  local issue_dir="$1" n="${2:-10}"
  local file="$issue_dir/checklist.md"
  [[ -f "$file" ]] || die "log_tail: no checklist at $file"
  awk '/^## Log/{p=1; next} p' "$file" | grep -E '^- [0-9]{4}-' | tail -n "$n"
}
