#!/usr/bin/env bash
# issue/gitlab.sh — GitLab issue backend.
# Prefers glab CLI; falls back to curl against REST v4 when glab is unavailable
# or when DEVAGENT_GITLAB_API is set (used by tests).
#
# Verbs (spec §9.1):
#   fetch        <repo> <num>                       → markdown to stdout
#   create       <repo> <title> <body-file> [--label X]…  → new <num>
#   transition   <repo> <num> <semantic-stage> [--project <name>]  → exit 0
#   state        <repo> <num>                       → backend state
#   comment-list <repo> <num>                       → markdown
#   state-list   <repo>                             → `<iid>\t<class>` lines
#                (optional verb, read by `wbs update`; #703)
#   issue-list   <repo>                             → JSON Lines records
#                (optional verb, read by `wbs init --from-tracker`; #706)
#   state-exists <repo> <label>                     → exit 0 present / 4 absent
#                (optional verb, the transition pre-check and doctor; #710)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/io.sh
source "${SCRIPT_DIR}/../lib/io.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"
# shellcheck source=../lib/transition.sh
source "${SCRIPT_DIR}/../lib/transition.sh"

usage() {
  cat <<EOF >&2
Usage: gitlab.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage> [--project <name>]
  state <repo> <num>
  comment-list <repo> <num>
  state-list <repo>
  issue-list <repo>
  state-exists <repo> <label>
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
    bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes")" || return "$(( $? == 6 ? 5 : $? ))"   # #774: a walk that does not end is this verb's 5

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

# _gl_stage_label <stage> <project>: the GitLab label a semantic stage names
# for <project>, or empty (no built-in default) — stage_map_target's
# precedence (env override, then gitlab_labels, then issue_workflow;
# scripts/lib/transition.sh). transition adds it; state-list and issue-list
# read on_draft_start's as the in-progress signal (#703, #710).
_gl_stage_label() { stage_map_target gitlab "${2:-}" "$1"; }

# _gl_label_exists <repo> <name>: 0 when the label is visible to <repo> — a
# project label or one of its ancestor groups' (#710 N7: GitLab answers a
# group label only with include_ancestor_groups=true; U1, asserted from
# GitLab's docs, unverified against a live instance) — 4 when it is not, 3
# auth refused, 1 any other failure. A failed lookup never answers 4: GitLab
# also 404s a label of a project the token cannot see (a private project and
# an under-scoped token) or a wrong path, so a label 404 is "absent" only when
# the project itself answers.
_gl_label_exists() {
  local enc; enc="$(urlenc "$1")"
  stage_state_probe "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    "$(api_base)/projects/${enc}/labels/$(urlenc "$2")?include_ancestor_groups=true" \
    "$(api_base)/projects/${enc}"
}

# transition <repo> <num> <semantic-stage> [--project <name>] (spec §9.1):
# check the target label exists BEFORE any write — GitLab creates a label
# named in add_labels that does not exist, and devagent never creates one
# (#87) — then read the issue and PUT the target with the other mapped stage
# labels it carries as remove_labels (the key is omitted when there are none),
# so it never holds in-progress, in-review and done together. Without
# --project only the env override is read (#710: never an ambient
# DEVAGENT_PROJECT). Already labelled with the target and no other stage label
# is success with no PUT. Exit: 0 landed / already there / no mapping (one
# warning, no request); 2 usage; 3 auth refused (401/403); 4 the label is not
# visible to the project, or the issue 404s; 1 anything else.
cmd_transition() {
  transition_args gitlab.sh "$@" || return
  local repo="$TA_REPO" num="$TA_NUM" stage="$TA_STAGE" project="$TA_PROJECT"
  local target others rc=0
  target="$(stage_map_target gitlab "$project" "$stage")" || return 1
  if [ -z "$target" ]; then
    transition_unmapped gitlab "$stage" "$project"
    return 0
  fi
  others="$(stage_map_others gitlab "$project" "$stage" "$target")" || return 1
  _gl_label_exists "$repo" "$target" || rc=$?
  case "$rc" in
    0) ;;
    4) echo "gitlab.sh: label '$target' ($stage) not found on $repo or its groups (or the project is not visible to this token); devagent does not create labels — create it or change the mapping" >&2
       return 4 ;;
    *) return "$rc" ;;
  esac
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local issue_json present remove
  issue_json="$(bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" GET "${base}/projects/${enc}/issues/${num}")" || return
  present="$(printf '%s' "$issue_json" | jq -r '.labels[]? | if type == "string" then . else .name end' | tr -d '\r')" || return 1
  # Only a stage label the issue carries is named for removal (an absent one is
  # a no-op, never an argument), in stage order.
  remove="$(stage_map_carried gitlab "$present" "$others")"
  remove="${remove//$'\n'/,}"
  if [ -n "$(stage_map_carried gitlab "$present" "$target")" ] && [ -z "$remove" ]; then
    return 0
  fi
  local payload
  payload="$(jq -nc --arg add "$target" --arg rm "$remove" \
    '{add_labels:$add} + (if $rm == "" then {} else {remove_labels:$rm} end)')"
  bc_curl_auth "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" PUT "${base}/projects/${enc}/issues/${num}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null
}

# state-exists <repo> <label> (#710, spec §9.1 MAY): 0 the label is visible to
# <repo> (project or ancestor group), 4 it is not, 2 usage; any other code is
# undetermined (3 auth refused, 1 any other failure). The transition
# pre-check and doctor's tracker check share _gl_label_exists.
cmd_state_exists() {
  { [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ]; } || usage
  _gl_label_exists "$1" "$2"
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
    bc_gitlab_paginate "${base}/projects/${enc}/issues/${num}/notes")" || return "$(( $? == 6 ? 5 : $? ))"
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
# opened + the on_draft_start label (_gl_stage_label, for the per-call
# DEVAGENT_PROJECT `wbs update` sets) -> in_progress; opened ->
# open. GitLab has no close reason, so never not_planned or other.
# Exit: 0 ok; 1 no repo arg; 3 HTTP 401/403 (bc_curl); other bc_curl codes
# for other HTTP failures; 5 a record with an unrecognised state,
# unreadable JSON (fail closed), or a paging walk that does not end (more
# than the page cap, or a repeated page; #774). Never 2, which means
# "unknown verb".
cmd_state_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "gitlab.sh state-list: repo required" >&2; exit 1; }
  local enc; enc="$(urlenc "$repo")"
  local base; base="$(api_base)"
  local ip; ip="$(_gl_stage_label on_draft_start "${DEVAGENT_PROJECT:-}")" || return 1
  local resp
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues")" || return "$(( $? == 6 ? 5 : $? ))"
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
# created_at, a page or links answer that is not a JSON array (fail
# closed), or a paging walk that does not end (more than the page cap, or a
# repeated page; #774). Never 2, which means "unknown verb".
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
  local ip; ip="$(_gl_stage_label on_draft_start "${DEVAGENT_PROJECT:-}")" || return 1
  local resp blockers iid src links pairs="" edges
  resp="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    bc_gitlab_paginate "${base}/projects/${enc}/issues")" || return "$(( $? == 6 ? 5 : $? ))"
  blockers="$(printf '%s' "$resp" \
    | jq -r '.[] | select((.blocking_issues_count // 0) > 0) | "\(.iid)\t\(.web_url)"' \
    | tr -d '\r')" || return 5
  while IFS=$'\t' read -r iid src; do
    [ -n "$iid" ] || continue
    links="$(BC_AUTH_HEADER="PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
      bc_curl GET "${base}/projects/${enc}/issues/${iid}/links")" || return
    pairs+="$(printf '%s' "$links" | jq -c --arg s "$src" --arg iid "$iid" '
      if type != "array" then error("links of #\($iid) is not a JSON array") else . end
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
  state-exists) cmd_state_exists "$@" ;;
  issue-list)   cmd_issue_list "$@" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
