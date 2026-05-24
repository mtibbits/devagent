#!/usr/bin/env bash
# backend-common.sh — shared helpers for issue/* and code/* backends.
# Source-only; do not execute.

# Returns 0 iff $1 is on PATH.
bc_have_cli() {
  command -v "$1" >/dev/null 2>&1
}

# Print a "not implemented" message to stderr and exit 78 (EX_CONFIG).
# Usage: bc_die_not_implemented <backend> <verb>
bc_die_not_implemented() {
  local backend="${1:-?}"
  local verb="${2:-?}"
  printf 'devagent: %s backend: verb "%s" is not implemented in this stub.\n' \
    "$backend" "$verb" >&2
  printf 'devagent: see README.md "Custom backends" for how to implement.\n' >&2
  exit 78
}

# Emit the spec §9.3 fetch header.
# Usage: bc_emit_fetch_header <repo> <num> <title> <state> <author> <labels-csv> <url>
bc_emit_fetch_header() {
  local repo="$1" num="$2" title="$3" state="$4" author="$5" labels="$6" url="$7"
  printf '# %s#%s — %s\n\n' "$repo" "$num" "$title"
  printf -- '- State: %s\n' "$state"
  printf -- '- Author: @%s\n' "$author"
  printf -- '- Labels: %s\n' "$labels"
  printf -- '- URL: %s\n' "$url"
  printf '\n---\n\n'
}

# Emit body block separator (spec §9.3: body verbatim, separated by ---).
# Usage: bc_emit_body_and_separator <body-text>
bc_emit_body_and_separator() {
  local body="$1"
  printf '%s\n\n---\n\n' "$body"
}

# Emit the comments section header.
# Usage: bc_emit_comments_header <count>
bc_emit_comments_header() {
  printf '## Comments (%s)\n\n' "$1"
}

# Emit one comment.
# Usage: bc_emit_comment <author> <date> <body>
bc_emit_comment() {
  local author="$1" date="$2" body="$3"
  printf '### @%s · %s\n\n%s\n\n' "$author" "$date" "$body"
}

# curl with sensible defaults for backend API calls.
# Maps HTTP status to our exit code conventions.
# Usage: bc_curl <method> <url> [extra curl args…]
# Writes body to stdout; exit 3 on auth failure, 4 on 404, 1 on other.
bc_curl() {
  local method="$1" url="$2"; shift 2
  local body_file http_status
  body_file="$(mktemp)"
  http_status="$(curl --silent --show-error \
    --connect-timeout 5 --max-time 30 \
    --retry 2 --retry-connrefused \
    -X "$method" \
    -o "$body_file" -w '%{http_code}' \
    "$@" "$url" 2>/dev/null || true)"
  cat "$body_file"
  rm -f "$body_file"
  case "$http_status" in
    2*) return 0 ;;
    401|403) return 3 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}
