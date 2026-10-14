#!/usr/bin/env bash
# code/gitlab.sh — GitLab code (MR) backend per spec §9.2.
# Verbs:
#   push-branch  <remote> <branch>
#   create-mr    <repo> <title> <body-file> <head> <base> [--draft]
#   mr-state     <mr-url>
#   mr-comments  <mr-url>
#   merge-mr     <mr-url> [--method squash|merge|rebase]
#   issue-mrs    <repo> <iid>...   (optional; #704)

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
  issue-mrs <repo> <iid>...
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
  # #88 (B1): a qualified `owner:branch` head denotes a cross-project MR (the
  # source branch lives in a different project). GitLab needs target_project_id
  # to express that, which this backend does not implement — fail loudly here,
  # BEFORE any POST, rather than file a same-project MR with a malformed
  # source_branch. Deferred to the backend-parity epic; use the github backend
  # for cross-fork MRs. (A git branch name cannot contain ':'.)
  case "$head" in
    *:*) echo "gitlab.sh: cross-project MR (head '$head') not supported — GitLab requires target_project_id; deferred to backend-parity. File within one project, or use the github backend." >&2; exit 2 ;;
  esac
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
  resp="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" POST "${base_url}/projects/${enc}/merge_requests" \
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
  resp="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET "${base}/projects/${enc}/merge_requests/${iid}")" || return
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
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/merge_requests/${iid}/notes")" || return
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
  # C18: default to squash to match code/github.sh, so switching backends does
  # not silently change merge semantics.
  local method="squash"
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
  bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" PUT "${base}/projects/${enc}/merge_requests/${iid}/merge" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

# issue-mrs <repo> <iid>... (#704, optional §9.2 verb): per issue, the MRs whose
# title or description closes it (scripts/lib/mr-link.py applies the rule and
# prints the grammar). Candidates are the issue's related_merge_requests, so
# fork MRs are seen whatever their target. One GET per issue; a page of 100
# or more exits 5 (fail-closed truncation, keeping the call bound at N).
# Exit: 0 ok (a 404 on a readable project is `missing` in-band); 1 bad args
# or a transport failure, or a 404 whose project probe also fails; 3 auth;
# 5 a body that is not a JSON array, a full page, or an unrecognised record.
cmd_issue_mrs() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "usage: gitlab.sh issue-mrs <repo> <iid>..." >&2; exit 1; }
  shift
  local iid
  for iid in "$@"; do
    [[ "$iid" =~ ^[0-9]+$ ]] || { echo "gitlab.sh: issue-mrs: not an issue iid: '$iid'" >&2; exit 1; }
  done
  [ $# -gt 0 ] || exit 0
  local enc base body n rc readable=0 recs
  enc="$(urlenc "$repo")"
  base="$(api_base)"
  recs="$(mktemp)"
  # shellcheck disable=SC2064  # expand $recs now
  trap "rm -f '$recs'" EXIT
  for iid in "$@"; do
    if body="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET \
        "${base}/projects/${enc}/issues/${iid}/related_merge_requests?per_page=100")"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 4 ]; then
      # A 404 is "no such issue" only on a project we can read; a hidden or
      # unauthorised project also answers 404.
      if [ "$readable" -eq 0 ]; then
        if bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET "${base}/projects/${enc}" >/dev/null; then
          readable=1
        else
          rc=$?
          echo "gitlab.sh: issue-mrs: project $repo is not readable" >&2
          [ "$rc" -eq 3 ] && exit 3
          exit 1
        fi
      fi
      printf '{"id":"%s","status":"missing","mrs":[]}\n' "$iid" >> "$recs"
      continue
    fi
    [ "$rc" -eq 0 ] || exit "$rc"
    n="$(printf '%s' "$body" | jq 'if type == "array" then length else error("not a JSON array") end' 2>/dev/null \
      | tr -d '\r')" || n=""
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "gitlab.sh: issue-mrs: issue $iid: response is not a JSON array" >&2; exit 5; }
    if [ "$n" -ge 100 ]; then
      echo "gitlab.sh: issue-mrs: issue $iid has 100+ related MRs (cap)" >&2
      exit 5
    fi
    # shellcheck disable=SC2016  # jq program
    if ! printf '%s' "$body" | jq -c --arg id "$iid" '{id: $id, status: "ok", mrs: [.[] | {
          repo: (.references.full | split("!")[0]),
          ref: .references.full,
          state: (if .state == "opened" or .state == "locked" then "open"
                  elif .state == "closed" then "closed" elif .state == "merged" then "merged"
                  else error("unrecognised MR state \(.state)") end),
          draft: (.draft // .work_in_progress // false),
          created: .created_at, merged: .merged_at,
          title: (.title // ""), body: (.description // "")}]}' >> "$recs"; then
      echo "gitlab.sh: issue-mrs: issue $iid: unrecognised MR record" >&2
      exit 5
    fi
  done
  python3 "${SCRIPT_DIR}/../lib/mr-link.py" emit gitlab "$repo" < "$recs"
}

verb="${1:-}"; shift || true
case "$verb" in
  push-branch) cmd_push_branch "$@" ;;
  create-mr)   cmd_create_mr "$@" ;;
  mr-state)    cmd_mr_state "$@" ;;
  mr-comments) cmd_mr_comments "$@" ;;
  merge-mr)    cmd_merge_mr "$@" ;;
  issue-mrs)   cmd_issue_mrs "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
