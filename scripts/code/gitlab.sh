#!/usr/bin/env bash
# code/gitlab.sh — GitLab code (MR) backend per spec §9.2.
# Verbs:
#   push-branch  <remote> <branch>
#   create-mr    <repo> <title> <body-file> <head> <base> [--draft]
#   mr-state     <mr-url>
#   mr-comments  <mr-url>
#   merge-mr     <mr-url> [--method squash|merge|rebase]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: gitlab.sh <verb> [args…]
  push-branch <remote> <branch>
  create-mr <repo> <title> <body-file> <head> <base> [--draft]
  mr-state <mr-url>
  mr-comments <mr-url>
  merge-mr <mr-url> [--method squash|merge|rebase]
EOF
  exit 2
}

api_base() {
  echo "${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
}

urlenc() {
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

trim_date() { echo "${1%%T*}"; }

# Parse an MR URL like https://host/<group>/<repo>/-/merge_requests/<iid>
parse_mr_url() {
  local url="$1"
  local path="${url#http://}"; path="${path#https://}"; path="${path#*/}"
  local repo="${path%%/-/merge_requests/*}"
  local iid="${path##*/merge_requests/}"
  iid="${iid%%/*}"
  echo "${repo}|${iid}"
}

cmd_push_branch() {
  local remote="${1:-}" branch="${2:-}"
  { [ -z "$remote" ] || [ -z "$branch" ]; } && usage
  git push "$remote" "$branch"
}

cmd_create_mr() {
  local repo="${1:-}" title="${2:-}" body_file="${3:-}" head="${4:-}" base="${5:-}"
  { [ -z "$repo" ] || [ -z "$title" ] || [ -z "$body_file" ] || [ -z "$head" ] || [ -z "$base" ]; } && usage
  [ -r "$body_file" ] || { echo "body file unreadable: $body_file" >&2; exit 2; }
  shift 5 || true
  local draft=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --draft) draft=1; shift ;;
      *) usage ;;
    esac
  done
  if [ "$draft" = "1" ]; then
    title="Draft: ${title}"
  fi
  local enc; enc="$(urlenc "$repo")"
  local base_url; base_url="$(api_base)"
  local payload
  payload="$(jq -nc \
    --arg t "$title" --rawfile d "$body_file" \
    --arg h "$head"  --arg b "$base" \
    '{title:$t, description:$d, source_branch:$h, target_branch:$b}')"
  local resp
  resp="$(bc_curl POST "${base_url}/projects/${enc}/merge_requests" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload")" || return
  echo "$resp" | jq -r '.web_url'
}

cmd_mr_state() {
  local url="${1:-}"; [ -z "$url" ] && usage
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/merge_requests/${iid}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local s d
  s="$(echo "$resp" | jq -r '.state')"
  d="$(echo "$resp" | jq -r '.draft // false')"
  if [ "$d" = "true" ]; then echo "draft"; return; fi
  case "$s" in
    opened) echo "open" ;;
    merged) echo "merged" ;;
    closed) echo "closed" ;;
    *) echo "$s" ;;
  esac
}

cmd_mr_comments() {
  local url="${1:-}"; [ -z "$url" ] && usage
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl GET "${base}/projects/${enc}/merge_requests/${iid}/notes" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}")" || return
  local count
  count="$(echo "$resp" | jq '[.[] | select(.system==false)] | length')"
  bc_emit_comments_header "$count"
  echo "$resp" | jq -c '.[] | select(.system==false)' | while read -r row; do
    local a dt b
    a="$(echo "$row" | jq -r '.author.username')"
    dt="$(trim_date "$(echo "$row" | jq -r '.created_at')")"
    b="$(echo "$row" | jq -r '.body')"
    bc_emit_comment "$a" "$dt" "$b"
  done
}

cmd_merge_mr() {
  local url="${1:-}"; shift || usage
  local method="merge"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  local parts; parts="$(parse_mr_url "$url")"
  local repo="${parts%%|*}" iid="${parts##*|}"
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  case "$method" in
    squash) payload='{"squash":true,"squash_commit_message":""}' ;;
    rebase) payload='{"merge_when_pipeline_succeeds":false,"should_remove_source_branch":false}' ;;
    merge|"") payload='{}' ;;
    *) echo "unknown --method: $method" >&2; exit 2 ;;
  esac
  bc_curl PUT "${base}/projects/${enc}/merge_requests/${iid}/merge" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

verb="${1:-}"; shift || true
case "$verb" in
  push-branch) cmd_push_branch "$@" ;;
  create-mr)   cmd_create_mr "$@" ;;
  mr-state)    cmd_mr_state "$@" ;;
  mr-comments) cmd_mr_comments "$@" ;;
  merge-mr)    cmd_merge_mr "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
