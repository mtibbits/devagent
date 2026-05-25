#!/usr/bin/env bash
# issue/jira.sh — JIRA issue backend per spec §9.1.
# curl only (no first-class CLI standardized).
#
# Auth: HTTP Basic with JIRA_USER:JIRA_TOKEN (Atlassian Cloud convention).
# Base URL via DEVAGENT_JIRA_BASE (e.g. https://acme.atlassian.net).

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

cmd_fetch() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local issue_json comments_json
  issue_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  comments_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/comment" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return

  local title state author labels url body
  title="$(echo "$issue_json"   | jq -r '.fields.summary')"
  state="$(echo "$issue_json"   | jq -r '.fields.status.name')"
  author="$(echo "$issue_json"  | jq -r '.fields.reporter.name')"
  labels="$(echo "$issue_json"  | jq -r '.fields.labels | join(",")')"
  body="$(echo "$issue_json"    | jq -r '.fields.description // ""')"
  url="$(base)/browse/${num}"

  bc_emit_fetch_header "$repo" "$num" "$title" "$state" "$author" "$labels" "$url"
  bc_emit_body_and_separator "$body"

  local count
  count="$(echo "$comments_json" | jq '.total')"
  bc_emit_comments_header "$count"
  echo "$comments_json" | jq -c '.comments[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.name')"
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
  resp="$(bc_curl POST "$(base)/rest/api/2/issue" \
    -H "$(auth_header)" \
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
    # shellcheck source=../lib/paths.sh
    source "${SCRIPT_DIR}/../lib/paths.sh"
    # shellcheck source=../lib/io.sh
    source "${SCRIPT_DIR}/../lib/io.sh"
    # shellcheck source=../lib/config.sh
    source "${SCRIPT_DIR}/../lib/config.sh"
    target_name="$(config_get_project_field "$DEVAGENT_PROJECT" "issue_workflow.${stage}" 2>/dev/null || true)"
  fi
  if [ -z "$target_name" ]; then
    echo "no JIRA stage mapping for '$stage'" >&2; exit 2
  fi

  local tr_json
  tr_json="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/transitions" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
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
  bc_curl POST "$(base)/rest/api/2/issue/${num}/transitions" \
    -H "$(auth_header)" \
    -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local resp
  resp="$(bc_curl GET "$(base)/rest/api/2/issue/${num}" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  echo "$resp" | jq -r '.fields.status.name'
}

cmd_comment_list() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local resp
  resp="$(bc_curl GET "$(base)/rest/api/2/issue/${num}/comment" \
    -H "$(auth_header)" -H 'Accept: application/json')" || return
  local count
  count="$(echo "$resp" | jq '.total')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.comments[]' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.name')"
    d="$(trim_date "$(echo "$row" | jq -r '.created')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch)        cmd_fetch "$@" ;;
  create)       cmd_create "$@" ;;
  transition)   cmd_transition "$@" ;;
  state)        cmd_state "$@" ;;
  comment-list) cmd_comment_list "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
