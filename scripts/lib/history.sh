#!/usr/bin/env bash
# scripts/lib/history.sh — chronological log merge across issues.
#
# Log line format (set by Plan 1's checklist library, see spec §5.2):
#   - YYYY-MM-DD HH:MM  <step>: <message>
#
# Output row format (pipe-delimited, stable for downstream parsing):
#   YYYY-MM-DD HH:MM|<issue>|<step>|<message>

# history_parse_log <checklist-file> <issue-id>
history_parse_log() {
  local file="$1" issue="$2"
  [ -f "${file}" ] || return 0
  awk -v issue="${issue}" '
    /^## *Log/ { in_log = 1; next }
    in_log && /^## / { in_log = 0; next }
    in_log && /^- *[0-9]{4}-[0-9]{2}-[0-9]{2} +[0-9]{2}:[0-9]{2} +/ {
      line = $0
      sub(/^- */, "", line)
      ts = substr(line, 1, 16)
      rest = substr(line, 17)
      sub(/^ +/, "", rest)
      colon = index(rest, ":")
      if (colon == 0) {
        step = rest; msg = ""
      } else {
        step = substr(rest, 1, colon - 1)
        msg  = substr(rest, colon + 1)
        sub(/^ +/, "", msg)
      }
      printf "%s|%s|%s|%s\n", ts, issue, step, msg
    }
  ' "${file}"
}

# history_issue <issue-dir> — prints sorted log for one issue.
history_issue() {
  local dir="$1"
  local id
  id="$(basename "${dir}")"
  history_parse_log "${dir}/checklist.md" "${id}" | LC_ALL=C sort
}

# history_project <devdoc-dir> — merges all Issue-* dirs, sorted ascending.
history_project() {
  local devdoc="$1"
  [ -d "${devdoc}" ] || return 0
  local issue_dir id
  for issue_dir in "${devdoc}"/Issue-*/; do
    [ -d "${issue_dir}" ] || continue
    id="$(basename "${issue_dir}")"
    history_parse_log "${issue_dir}/checklist.md" "${id}"
  done | LC_ALL=C sort
}
