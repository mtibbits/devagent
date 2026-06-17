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
  # #92: when BC_AUTH_HEADER is set, feed it to curl as a --config read from
  # stdin rather than an argv `-H` — argv is world-readable via
  # /proc/<pid>/cmdline for the life of the request. printf is a bash builtin, so
  # the token never reaches any external process's argv. Non-secret flags/data
  # stay in "$@". With no auth header, no --config is added and curl's stdin (an
  # empty pipe) is ignored.
  local cfg=() auth_cfg=""
  if [ -n "${BC_AUTH_HEADER:-}" ]; then
    cfg=(--config -)
    # curl --config quoted-value syntax: escape \ then " so a token with those
    # chars can't break out of the quotes (real GitLab PAT / Jira base64 charsets
    # never contain them; this is defensive).
    auth_cfg="${BC_AUTH_HEADER//\\/\\\\}"
    auth_cfg="${auth_cfg//\"/\\\"}"
  fi
  http_status="$( { [ -n "${BC_AUTH_HEADER:-}" ] && printf 'header = "%s"\n' "$auth_cfg"; :; } \
    | curl --silent --show-error \
    --connect-timeout 5 --max-time 30 \
    --retry 2 --retry-connrefused \
    -X "$method" \
    -o "$body_file" -w '%{http_code}' \
    "${cfg[@]}" "$@" "$url" 2>/dev/null || true)"
  cat "$body_file"
  case "$http_status" in
    2*) rm -f "$body_file"; return 0 ;;
  esac
  # #138: non-2xx — surface the status and error body to stderr. Callers capture
  # stdout into a var and discard it on `|| return`, and bc_curl suppresses
  # curl's own stderr, so without this an expired token kills /devagent:file and
  # /devagent:ship under set -e with no diagnostic at all.
  { printf 'bc_curl: %s %s -> HTTP %s\n' "$method" "$url" "${http_status:-000}"
    cat "$body_file"; } >&2
  rm -f "$body_file"
  case "$http_status" in
    401|403) return 3 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}

# bc_curl_auth <auth-header> <method> <url> [extra curl args…]
# Like bc_curl, but delivers <auth-header> (e.g. "PRIVATE-TOKEN: <token>" or
# "Authorization: Basic <b64>") to curl via stdin --config instead of argv, so
# the token is never exposed in /proc/<pid>/cmdline (#92). Honors the same exit
# conventions as bc_curl.
bc_curl_auth() {
  local header="$1"; shift
  BC_AUTH_HEADER="$header" bc_curl "$@"
}

# Fetch every page of a GitLab list endpoint and emit one concatenated JSON
# array (#137). GitLab defaults to 20 items/page; without paging, notes past the
# first page are silently dropped. bc_curl exposes only the body (not the
# X-Next-Page header), so we page-loop with per_page=100 and stop at the first
# short page (a page with < 100 items is the last).
#   Usage: bc_gitlab_paginate <url-without-query> [extra curl args…]
bc_gitlab_paginate() {
  local url="$1"; shift
  local page=1 acc="[]" pg n
  while :; do
    pg="$(bc_curl GET "${url}?per_page=100&page=${page}" "$@")" || return
    n="$(printf '%s' "$pg" | jq 'length')"
    acc="$(printf '%s\n%s\n' "$acc" "$pg" | jq -s 'add')"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  printf '%s' "$acc"
}

# Fetch every page of a Jira /comment endpoint and emit one concatenated JSON
# array of comment objects (#137). Jira caps the body at maxResults while
# reporting the true count in .total; without paging the body under-delivers the
# promised comments. Loop startAt+=page-length until a page is empty or we have
# reached .total.
#   Usage: bc_jira_paginate <url-without-query> [extra curl args…]
bc_jira_paginate() {
  local url="$1"; shift
  local start=0 acc="[]" resp pg got total
  while :; do
    resp="$(bc_curl GET "${url}?startAt=${start}&maxResults=100" "$@")" || return
    pg="$(printf '%s' "$resp" | jq '.comments // []')"
    got="$(printf '%s' "$pg" | jq 'length')"
    total="$(printf '%s' "$resp" | jq '.total // 0')"
    acc="$(printf '%s\n%s\n' "$acc" "$pg" | jq -s 'add')"
    start=$((start + got))
    { [ "$got" -eq 0 ] || [ "$start" -ge "$total" ]; } && break
  done
  printf '%s' "$acc"
}
