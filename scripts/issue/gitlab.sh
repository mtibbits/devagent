#!/usr/bin/env bash
# issue/gitlab.sh — GitLab issue backend.
# Prefers glab CLI; falls back to curl against REST v4 when glab is unavailable
# or when DEVAGENT_GITLAB_API is set (used by tests).
#
# Verbs (spec §9.1):
#   fetch        <repo> <num>                       → markdown to stdout
#   create       <repo> <title> <body-file> [--label X]…  → new <num>
#   transition   <repo> <num> <semantic-stage>      → exit 0
#   state        <repo> <num>                       → backend state
#   comment-list <repo> <num>                       → markdown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: gitlab.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>
EOF
  exit 2
}

api_base() {
  echo "${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
}

urlenc() {
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

trim_date() {
  echo "${1%%T*}"
}

# --- verbs -------------------------------------------------------------------

cmd_fetch() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local issue_json comments_json
  issue_json="$(bc_curl GET "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  comments_json="$(bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return

  local title state author labels url body
  title="$(echo "$issue_json" | jq -r '.title')"
  state="$(echo "$issue_json" | jq -r '.state')"
  author="$(echo "$issue_json" | jq -r '.author.username')"
  labels="$(echo "$issue_json" | jq -r '.labels | join(",")')"
  url="$(echo "$issue_json" | jq -r '.web_url')"
  body="$(echo "$issue_json" | jq -r '.description // ""')"

  bc_emit_fetch_header "$repo" "$num" "$title" "$state" "$author" "$labels" "$url"
  bc_emit_body_and_separator "$body"

  local count
  count="$(echo "$comments_json" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"

  echo "$comments_json" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.username')"
    d="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
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
  local labels_csv=""
  if [ "${#labels[@]}" -gt 0 ]; then
    labels_csv="$(IFS=,; echo "${labels[*]}")"
  fi

  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  payload="$(jq -n --arg t "$title" --rawfile d "$body_file" --arg l "$labels_csv" \
    '{title:$t, description:$d} + (if $l == "" then {} else {labels:$l} end)')"
  local resp
  resp="$(bc_curl POST "${base}/projects/${enc}/issues" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload")" || return
  echo "$resp" | jq -r '.iid'
}

cmd_transition() {
  local repo="${1:-}" num="${2:-}" stage="${3:-}"
  { [ -z "$repo" ] || [ -z "$num" ] || [ -z "$stage" ]; } && usage

  local add_label remove_prefix
  local var_add="DEVAGENT_GITLAB_LABELS_$(echo "$stage" | tr '[:lower:]' '[:upper:]' | tr - _)"
  add_label="${!var_add:-}"
  remove_prefix="${DEVAGENT_GITLAB_LABEL_NAMESPACE:-}"

  if [ -z "$add_label" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    # shellcheck source=../lib/paths.sh
    source "${SCRIPT_DIR}/../lib/paths.sh"
    # shellcheck source=../lib/io.sh
    source "${SCRIPT_DIR}/../lib/io.sh"
    # shellcheck source=../lib/config.sh
    source "${SCRIPT_DIR}/../lib/config.sh"
    add_label="$(config_get_project_field "$DEVAGENT_PROJECT" "gitlab_labels.${stage}" 2>/dev/null || true)"
    remove_prefix="$(config_get_project_field "$DEVAGENT_PROJECT" "gitlab_labels.remove_others_in_namespace" 2>/dev/null || true)"
  fi

  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  payload="$(jq -n --arg add "$add_label" --arg rmprefix "$remove_prefix" \
    '{add_labels:$add} + (if $rmprefix=="" then {} else {remove_labels:$rmprefix} end)')"
  bc_curl PUT "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/issues/${num}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  echo "$resp" | jq -r '.state'
}

cmd_comment_list() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local count
  count="$(echo "$resp" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a d b
    a="$(echo "$row" | jq -r '.author.username')"
    d="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$d" "$b"
  done
}

# --- dispatch ----------------------------------------------------------------

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
