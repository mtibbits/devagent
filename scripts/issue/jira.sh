#!/usr/bin/env bash
# issue/jira.sh — JIRA issue backend per spec §9.1.
# curl only (no first-class CLI standardized).
#
# Auth: HTTP Basic with JIRA_USER:JIRA_TOKEN (Atlassian Cloud convention).
# Base URL via DEVAGENT_JIRA_BASE (e.g. https://acme.atlassian.net).
#
# state-list <repo> (#703) is the optional verb `wbs update` reads; it emits
# issue KEYS (`PROJ-12`), not the internal ids the per-issue verbs take.
# issue-list <repo> (#706) is the optional verb `wbs init --from-tracker`
# reads; its records are keyed the same way. Both are Jira Cloud only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: jira.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>
  state-list <repo>
  issue-list <repo>
EOF
  exit 2
}

base() { echo "${DEVAGENT_JIRA_BASE:-https://jira.example}"; }

auth_header() {
  local raw
  raw="$(printf '%s:%s' "${JIRA_USER:-}" "${JIRA_TOKEN:-}" | base64 | tr -d '\n')"
  printf 'Authorization: Basic %s' "$raw"
}

trim_date() { echo "${1%%T*}"; }

# Percent-encode one query value (jq @uri: unreserved chars kept, space ->
# %20, never +). Same encoding gitlab.sh's urlenc produces.
_urlenc() { jq -rn --arg s "$1" '$s | @uri' | tr -d '\r'; }

_jira_load_config() {
  # shellcheck source=../lib/paths.sh
  source "${SCRIPT_DIR}/../lib/paths.sh"
  # shellcheck source=../lib/io.sh
  source "${SCRIPT_DIR}/../lib/io.sh"
  # shellcheck source=../lib/config.sh
  source "${SCRIPT_DIR}/../lib/config.sh"
}

cmd_fetch() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local issue_json comments_json
  issue_json="$(bc_curl_auth "$(auth_header)" GET "$(base)/rest/api/2/issue/${num}" \
    -H 'Accept: application/json')" || return
  comments_json="$(BC_AUTH_HEADER="$(auth_header)" \
    bc_jira_paginate "$(base)/rest/api/2/issue/${num}/comment" -H 'Accept: application/json')" || return

  local title state author labels url body
  title="$(echo "$issue_json"   | jq -r '.fields.summary')"
  state="$(echo "$issue_json"   | jq -r '.fields.status.name')"
  author="$(echo "$issue_json"  | jq -r '.fields.reporter.displayName // .fields.reporter.name // "unknown"')"
  labels="$(echo "$issue_json"  | jq -r '.fields.labels | join(",")')"
  body="$(echo "$issue_json"    | jq -r '.fields.description // ""')"
  url="$(base)/browse/${num}"

  bc_emit_fetch_header "$repo" "$num" "$title" "$state" "$author" "$labels" "$url"
  bc_emit_body_and_separator "$body"

  local count
  count="$(echo "$comments_json" | jq 'length')"
  bc_emit_comments_header "$count"
  echo "$comments_json" | jq -c '.[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.displayName // .author.name // "unknown"')"
    d="$(trim_date "$(echo "$row" | jq -r '.created')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

cmd_create() {
  local repo="${1:-}" title="${2:-}" body_file="${3:-}"
  { [ -z "$repo" ] || [ -z "$title" ] || [ -z "$body_file" ]; } && usage
  [ -r "$body_file" ] || { echo "body file unreadable: $body_file" >&2; exit 2; }
  shift 3 || true
  local labels=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) labels+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  local issue_type="${DEVAGENT_JIRA_ISSUE_TYPE:-Task}"
  local project_key="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
  local labels_json
  if [ "${#labels[@]}" -gt 0 ]; then
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -sc .)"
  else
    labels_json="[]"
  fi
  local payload
  payload="$(jq -nc \
    --arg pk "$project_key" --arg t "$title" \
    --rawfile d "$body_file" --arg it "$issue_type" \
    --argjson labels "$labels_json" \
    '{fields:{project:{key:$pk},summary:$t,description:$d,issuetype:{name:$it},labels:$labels}}')"
  local resp
  resp="$(bc_curl_auth "$(auth_header)" POST "$(base)/rest/api/2/issue" \
    -H 'Content-Type: application/json' \
    --data "$payload")" || return
  echo "$resp" | jq -r '.key'
}

cmd_transition() {
  local repo="${1:-}" num="${2:-}" stage="${3:-}"
  { [ -z "$repo" ] || [ -z "$num" ] || [ -z "$stage" ]; } && usage

  local var="DEVAGENT_JIRA_STAGE_$(echo "$stage" | tr '[:lower:]' '[:upper:]' | tr - _)"
  local target_name="${!var:-}"
  if [ -z "$target_name" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    _jira_load_config
    target_name="$(config_get_project_field "$DEVAGENT_PROJECT" "issue_workflow.${stage}" 2>/dev/null || true)"
  fi
  if [ -z "$target_name" ]; then
    echo "no JIRA stage mapping for '$stage'" >&2; exit 2
  fi

  local tr_json
  tr_json="$(bc_curl_auth "$(auth_header)" GET "$(base)/rest/api/2/issue/${num}/transitions" \
    -H 'Accept: application/json')" || return
  local id
  id="$(echo "$tr_json" | jq -r --arg n "$target_name" \
    '.transitions[] | select(.to.name==$n) | .id' | head -n1)"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    # Per spec §11: failed transitions log but do not block real work.
    echo "warn: no transition to '$target_name' available; logged-only" >&2
    return 0
  fi
  local payload
  payload="$(jq -nc --arg id "$id" '{transition:{id:$id}}')"
  bc_curl_auth "$(auth_header)" POST "$(base)/rest/api/2/issue/${num}/transitions" \
    -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local resp
  resp="$(bc_curl_auth "$(auth_header)" GET "$(base)/rest/api/2/issue/${num}" \
    -H 'Accept: application/json')" || return
  echo "$resp" | jq -r '.fields.status.name'
}

cmd_comment_list() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local resp
  resp="$(BC_AUTH_HEADER="$(auth_header)" \
    bc_jira_paginate "$(base)/rest/api/2/issue/${num}/comment" -H 'Accept: application/json')" || return
  local count
  count="$(echo "$resp" | jq 'length')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.displayName // .author.name // "unknown"')"
    d="$(trim_date "$(echo "$row" | jq -r '.created')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

# The resolution names state-list reads as not_planned: env
# DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS (newline-separated), else the
# project's `issue_workflow.not_planned_resolutions` string array, else none.
# Printed as a JSON array.
_jira_not_planned() {
  local list="${DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS:-}"
  if [ -z "$list" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    _jira_load_config
    list="$(config_get_project_list "$DEVAGENT_PROJECT" issue_workflow.not_planned_resolutions 2>/dev/null || true)"
  fi
  printf '%s\n' "$list" | tr -d '\r' | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# _jira_search_all <key> <fields>: every issue of the project, as one JSON
# array: the enhanced JQL search, paged on nextPageToken until isLast (or no
# token). A token seen before (a repeat or a longer cycle), or more than
# _JIRA_MAX_PAGES pages, returns 5 (#706: the server is not trusted to end
# the walk).
_JIRA_MAX_PAGES=1000
_jira_search_all() {
  local key="$1" fields="$2" url tok="" pages="" resp out page last u auth n=0
  local -A seen=()
  url="$(base)/rest/api/2/search/jql?jql=$(_urlenc "project = \"${key}\" ORDER BY key")&fields=${fields}&maxResults=100"
  auth="$(auth_header)"
  while :; do
    if (( n >= _JIRA_MAX_PAGES )); then
      echo "jira.sh: search stopped at its cap of ${_JIRA_MAX_PAGES} pages" >&2
      return 5
    fi
    n=$((n + 1))
    u="$url"
    [ -z "$tok" ] || u="${url}&nextPageToken=$(_urlenc "$tok")"
    resp="$(bc_curl_auth "$auth" GET "$u" -H 'Accept: application/json')" || return
    # One jq per page: `<isLast> TAB <nextPageToken>`, then the issues array.
    # (an `||` caller disables set -e here, so each jq checks its own rc)
    out="$(printf '%s' "$resp" \
      | jq -r '"\(.isLast // false)\t\(.nextPageToken // "")", (.issues // [] | tojson)' \
      | tr -d '\r')" || return 5
    { IFS=$'\t' read -r last tok; IFS= read -r page; } <<<"$out"
    pages+="$page"$'\n'
    { [ "$last" = true ] || [ -z "$tok" ]; } && break
    if [ -n "${seen[$tok]:-}" ]; then
      echo "jira.sh: nextPageToken repeated ($tok); stopping" >&2
      return 5
    fi
    seen[$tok]=1
  done
  printf '%s' "$pages" | jq -s 'add // []' || return 5
}

# jira_class($np): an issue's state-list class; state-list and issue-list
# both prepend it, so the two verbs cannot drift (#706).
_JIRA_CLASS_JQ='
  def jira_class($np):
    (.fields.status.statusCategory.key // "") as $c
    | (.fields.resolution.name // "") as $r
    | if $c == "done" then (if any($np[]; . == $r) then "not_planned" else "done" end)
      elif $c == "indeterminate" then "in_progress"
      elif $c == "new" then "open"
      elif $c == "undefined" then "other"
      else error("unrecognised statusCategory \($c) on \(.key)") end;'

# state-list <repo> (#703, spec §9.1 MAY): every issue of the project, one
# `<key>` TAB `<class>` line each, for `wbs update`. The project key is
# ${DEVAGENT_JIRA_PROJECT_KEY:-<repo>}, as cmd_create uses. Classes by
# statusCategory.key: done -> done (not_planned when the resolution is a
# listed not-planned one, _jira_not_planned); indeterminate -> in_progress;
# new -> open; undefined ("No Category", a legitimate fourth value) -> other.
# Exit: 0 ok; 1 no repo arg; 3 HTTP 401/403 (bc_curl); other
# bc_curl codes for other HTTP failures; 5 a record with an unrecognised
# status category or unreadable JSON (fail closed). Never 2 ("unknown verb").
cmd_state_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "jira.sh state-list: repo required" >&2; exit 1; }
  local key="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
  local np all
  np="$(_jira_not_planned)" || return 5
  all="$(_jira_search_all "$key" status,resolution)" || return
  printf '%s' "$all" | jq -r --argjson np "$np" "$_JIRA_CLASS_JQ"'
    .[] | "\(.key)\t\(jira_class($np))"' || return 5
}

# issue-list <repo> (#706, spec §9.1 MAY): every issue of the project as one
# JSON Lines record (contract: scripts/lib/wbs-import.py), sorted by key, for
# `wbs init --from-tracker`. The same search as state-list, with more fields.
# Mapping: id <- key; state closed iff statusCategory done; class <-
# jira_class; title <- summary; body <- description (null -> ""); created
# <- created (date part); closed <- resolutiondate, else
# statuscategorychangedate (date part) when closed; milestone null (Jira has
# none; fixVersions is not read); labels <- labels; type <-
# issuetype.name; parent <- <base>/browse/<parent.key>; blocked_by <- the
# Blocks links holding an inwardIssue (on issue X, inwardIssue Y reads "X is
# blocked by Y"; Issue-706 U3, ASSERTED from Atlassian's link-type docs);
# url <- <base>/browse/<key>.
# Exit: 0 ok; 1 no repo arg; 3 HTTP 401/403 (bc_curl); other bc_curl codes
# for other HTTP failures; 5 an unrecognised status category, unreadable
# JSON, or a paging walk that does not end (fail closed). Never 2.
_JIRA_ISSUE_JQ='
  sort_by(.key) | .[] | jira_class($np) as $cls
  | (if (.fields.status.statusCategory.key // "") == "done" then "closed" else "open" end) as $st
  | {id: .key, title: (.fields.summary // ""), body: (.fields.description // ""),
     state: $st, class: $cls, created: ((.fields.created // "")[0:10]),
     closed: (if $st == "closed"
              then ((.fields.resolutiondate // .fields.statuscategorychangedate // "")[0:10])
              else null end),
     milestone: null,
     labels: (.fields.labels // []),
     type: (.fields.issuetype.name // null),
     parent: (if .fields.parent.key then "\($base)/browse/\(.fields.parent.key)" else null end),
     blocked_by: [.fields.issuelinks[]?
                  | select(.type.name == "Blocks" and .inwardIssue.key)
                  | "\($base)/browse/\(.inwardIssue.key)"],
     url: "\($base)/browse/\(.key)"}'

cmd_issue_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "jira.sh issue-list: repo required" >&2; exit 1; }
  local key="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
  local np all b
  np="$(_jira_not_planned)" || return 5
  all="$(_jira_search_all "$key" \
    summary,description,status,resolution,created,resolutiondate,statuscategorychangedate,labels,issuetype,parent,issuelinks)" \
    || return
  b="$(base)"
  printf '%s' "$all" | jq -c --argjson np "$np" --arg base "${b%/}" "$_JIRA_CLASS_JQ$_JIRA_ISSUE_JQ" || return 5
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch)        cmd_fetch "$@" ;;
  create)       cmd_create "$@" ;;
  transition)   cmd_transition "$@" ;;
  state)        cmd_state "$@" ;;
  comment-list) cmd_comment_list "$@" ;;
  state-list)   cmd_state_list "$@" ;;
  issue-list)   cmd_issue_list "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
