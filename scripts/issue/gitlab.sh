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
#   state-list   <repo>                             → `<iid>\t<class>` lines
#                (optional verb, read by `wbs update`; #703)
#   issue-list   <repo>                             → JSON Lines records
#                (optional verb, read by `wbs init --from-tracker`; #706)

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
  state-list <repo>
  issue-list <repo>
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
  issue_json="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET "${base}/projects/${enc}/issues/${num}")" || return
  comments_json="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes")" || return

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
  resp="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" POST "${base}/projects/${enc}/issues" \
    -H "Content-Type: application/json" \
    --data "$payload")" || return
  echo "$resp" | jq -r '.iid'
}

_gl_load_config() {
  # shellcheck source=../lib/paths.sh
  source "${SCRIPT_DIR}/../lib/paths.sh"
  # shellcheck source=../lib/io.sh
  source "${SCRIPT_DIR}/../lib/io.sh"
  # shellcheck source=../lib/config.sh
  source "${SCRIPT_DIR}/../lib/config.sh"
}

# _gl_stage_var <stage>: the env override's name, DEVAGENT_GITLAB_LABELS_<STAGE>.
_gl_stage_var() {
  printf 'DEVAGENT_GITLAB_LABELS_%s' "$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr - _)"
}

# _gl_stage_label <stage>: the label for a semantic stage —
# the _gl_stage_var env, else the project's
# `gitlab_labels.<stage>` config, else empty (no built-in default).
# transition adds it; state-list reads in_progress from it (#703).
_gl_stage_label() {
  local stage="$1" var label
  var="$(_gl_stage_var "$stage")"
  label="${!var:-}"
  if [ -z "$label" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    _gl_load_config
    label="$(config_get_project_field "$DEVAGENT_PROJECT" "gitlab_labels.${stage}" 2>/dev/null || true)"
  fi
  printf '%s' "$label"
}

cmd_transition() {
  local repo="${1:-}" num="${2:-}" stage="${3:-}"
  { [ -z "$repo" ] || [ -z "$num" ] || [ -z "$stage" ]; } && usage

  local add_label remove_prefix
  local var_add
  var_add="$(_gl_stage_var "$stage")"
  add_label="$(_gl_stage_label "$stage")"
  remove_prefix="${DEVAGENT_GITLAB_LABEL_NAMESPACE:-}"

  if [ -z "${!var_add:-}" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    _gl_load_config
    remove_prefix="$(config_get_project_field "$DEVAGENT_PROJECT" "gitlab_labels.remove_others_in_namespace" 2>/dev/null || true)"
  fi

  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local payload
  payload="$(jq -n --arg add "$add_label" --arg rmprefix "$remove_prefix" \
    '{add_labels:$add} + (if $rmprefix=="" then {} else {remove_labels:$rmprefix} end)')"
  bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" PUT "${base}/projects/${enc}/issues/${num}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

cmd_state() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET "${base}/projects/${enc}/issues/${num}")" || return
  echo "$resp" | jq -r '.state'
}

cmd_comment_list() {
  local repo="${1:-}" num="${2:-}"
  { [ -z "$repo" ] || [ -z "$num" ]; } && usage
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local resp
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes")" || return
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

# gl_class($ip): a GitLab issue's state-list class; state-list and issue-list
# both prepend it, so the two verbs cannot drift (#706).
_GL_CLASS_JQ='
  def gl_class($ip):
    if .state == "closed" then "done"
    elif .state == "opened" then
      (if $ip != "" and any(.labels[]?; . == $ip) then "in_progress" else "open" end)
    else error("unrecognised state \(.state) on #\(.iid)") end;'

# state-list <repo> (#703, spec §9.1 MAY): every issue of <repo>, one
# `<iid>` TAB `<class>` line each, for `wbs update`. Pages the issues list
# (no `state` filter returns opened and closed). Classes: closed -> done;
# opened + the in_progress label (_gl_stage_label) -> in_progress; opened ->
# open. GitLab has no close reason, so never not_planned or other.
# Exit: 0 ok; 1 no repo arg; 3 HTTP 401/403 (bc_curl); other bc_curl codes
# for other HTTP failures; 5 a record with an unrecognised state or
# unreadable JSON (fail closed). Never 2, which means "unknown verb".
cmd_state_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "gitlab.sh state-list: repo required" >&2; exit 1; }
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local ip; ip="$(_gl_stage_label in_progress)"
  local resp
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues")" || return
  printf '%s' "$resp" | jq -r --arg ip "$ip" "$_GL_CLASS_JQ"'
    .[] | "\(.iid)\t\(gl_class($ip))"' || return 5
}

# issue-list <repo> (#706, spec §9.1 MAY): every issue of <repo> as one JSON
# Lines record (contract: scripts/lib/wbs-import.py), sorted by iid, for
# `wbs init --from-tracker`. Pages the same issues list as state-list. Each
# issue whose blocking_issues_count is above 0 (the issues IT blocks;
# measured, Issue-706 U4) costs one GET .../issues/<iid>/links; every
# `blocks` link puts this issue's web_url into the target's blocked_by,
# matched by web_url (a target outside the list is dropped).
# Mapping: id <- iid; state opened/closed -> open/closed; class <- gl_class;
# title <- title; body <- description (null -> ""); created <- created_at,
# closed <- closed_at, else updated_at (GitLab before 10.6 did not record
# closed_at), date part; milestone <- milestone.title; labels <-
# labels; type <- issue_type; parent null (GitLab epics are out of scope);
# url <- web_url.
# Exit: 0 ok; 1 no repo arg; 3 HTTP 401/403 (bc_curl); other bc_curl codes
# for other HTTP failures; 5 an unrecognised state, a record without
# created_at, or a page or links answer that is not a JSON array (fail
# closed). Never 2, which means "unknown verb".
_GL_ISSUE_JQ='
  sort_by(.iid) | .[]
  | if (.created_at // "") == "" then error("record #\(.iid) lacks created_at") else . end
  | gl_class($ip) as $cls
  | (if .state == "closed" then "closed" else "open" end) as $st
  | {id: (.iid | tostring), title: (.title // ""), body: (.description // ""),
     state: $st, class: $cls, created: .created_at[0:10],
     closed: (if $st == "closed" then ((.closed_at // .updated_at // "")[0:10]) else null end),
     milestone: (.milestone.title // null),
     labels: [.labels[]? | if type == "string" then . else .name end],
     type: (.issue_type // null), parent: null,
     blocked_by: ($edges[.web_url] // []), url: .web_url}'

cmd_issue_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "gitlab.sh issue-list: repo required" >&2; exit 1; }
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local ip; ip="$(_gl_stage_label in_progress)"
  local resp blockers iid src links pairs="" edges
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues")" || return
  blockers="$(printf '%s' "$resp" \
    | jq -r '.[] | select((.blocking_issues_count // 0) > 0) | "\(.iid)\t\(.web_url)"' \
    | tr -d '\r')" || return 5
  while IFS=$'\t' read -r iid src; do
    [ -n "$iid" ] || continue
    links="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
      bc_curl GET "${base}/projects/${enc}/issues/${iid}/links")" || return
    pairs+="$(printf '%s' "$links" | jq -c --arg s "$src" '
      if type != "array" then error("links of #'"$iid"' is not a JSON array") else . end
      | map(select(.link_type == "blocks") | {t: .web_url, s: $s})')"$'\n' || return 5
  done <<<"$blockers"
  edges="$(printf '%s' "$pairs" | jq -cs 'add // [] | group_by(.t)
    | map({key: .[0].t, value: (map(.s) | unique)}) | from_entries')" || return 5
  printf '%s' "$resp" | jq -c --arg ip "$ip" --argjson edges "$edges" "$_GL_CLASS_JQ$_GL_ISSUE_JQ" || return 5
}

# --- dispatch ----------------------------------------------------------------

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
