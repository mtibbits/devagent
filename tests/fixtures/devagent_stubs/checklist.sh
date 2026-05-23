#!/usr/bin/env bash
# Stub for scripts/lib/checklist.sh (Plan 1). Real impl parses the full
# checklist.md format; stub only implements `checklist_log_entries`.

checklist_log_entries() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  awk '
    BEGIN { in_log = 0 }
    /^## Log[[:space:]]*$/ { in_log = 1; next }
    /^## / { in_log = 0 }
    in_log && /^- [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
      line = $0
      sub(/^- /, "", line)
      ts = substr(line, 1, 16)
      rest = substr(line, 17)
      sub(/^[[:space:]]+/, "", rest)
      colon = index(rest, ":")
      if (colon == 0) next
      step = substr(rest, 1, colon - 1)
      msg = substr(rest, colon + 1)
      sub(/^[[:space:]]+/, "", msg)
      gsub(/\\/, "\\\\", msg)
      gsub(/"/, "\\\"", msg)
      printf "{\"ts\": \"%s\", \"step\": \"%s\", \"message\": \"%s\"}\n", ts, step, msg
    }
  ' "$path"
}
export -f checklist_log_entries
