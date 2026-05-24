#!/usr/bin/env bash
# scripts/issue/github.sh — GitHub issue backend.
# Backend contract: implements all five issue verbs per spec §9.1
# (fetch, create, transition, state, comment-list).
# Output shape conforms to spec §9.3.

set -euo pipefail

_die() { echo "$*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "$1 not found on PATH"; }

cmd_fetch() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq

  local json
  if ! json="$(gh issue view "$num" --repo "$repo" --json \
    title,state,author,labels,url,body,comments 2>&1)"; then
    echo "gh issue view failed: $json" >&2
    return 1
  fi

  printf '%s' "$json" | jq -r --arg repo "$repo" --arg num "$num" '
    def label_csv:
      if (.labels|length) == 0 then "" else
        (.labels | map(.name) | join(", "))
      end;
    def comment_block:
      .comments | map(
        "### @" + (.author.login // "unknown")
        + " · " + ((.createdAt // "") | split("T")[0])
        + "\n\n" + (.body // "")
      ) | join("\n\n");

    "# " + $repo + "#" + $num + " — " + (.title // "(no title)") + "\n\n"
    + "- State: " + ((.state // "unknown") | ascii_downcase) + "\n"
    + "- Author: @" + (.author.login // "unknown") + "\n"
    + "- Labels: " + label_csv + "\n"
    + "- URL: " + (.url // "") + "\n\n"
    + "---\n\n"
    + (.body // "") + "\n\n"
    + "---\n\n"
    + "## Comments (" + ((.comments | length) | tostring) + ")\n"
    + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
  '
}

cmd_state() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq
  local json
  json="$(gh issue view "$num" --repo "$repo" --json state 2>&1)" || {
    echo "gh issue view failed: $json" >&2
    return 1
  }
  printf '%s' "$json" | jq -r '.state | ascii_downcase'
}

cmd_comment_list() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq
  local json
  json="$(gh issue view "$num" --repo "$repo" --json comments 2>&1)" || {
    echo "gh issue view failed: $json" >&2
    return 1
  }
  printf '%s' "$json" | jq -r '
    def comment_block:
      .comments | map(
        "### @" + (.author.login // "unknown")
        + " · " + ((.createdAt // "") | split("T")[0])
        + "\n\n" + (.body // "")
      ) | join("\n\n");
    "## Comments (" + ((.comments | length) | tostring) + ")\n"
    + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
  '
}

cmd_create() {
  local repo="${1:?repo required}"
  local title="${2:?title required}"
  local body_file="${3:-}"
  _need gh
  if [ -n "${body_file}" ] && [ -f "${body_file}" ]; then
    gh issue create --repo "$repo" --title "$title" --body-file "$body_file"
  else
    gh issue create --repo "$repo" --title "$title" --body "${body_file:-}"
  fi
}

# Semantic-stage to label map (overridable per project).
#   in_progress → "in progress"  (lowercase, conventional GitHub label)
#   done        → "done"
#   blocked     → "blocked"
# Override via DEVAGENT_GITHUB_LABEL_<STAGE>=label-name in the env.
cmd_transition() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  local stage="${3:?semantic stage required}"
  _need gh
  local var="DEVAGENT_GITHUB_LABEL_${stage^^}"
  local label="${!var:-}"
  if [ -z "$label" ]; then
    case "$stage" in
      in_progress) label="in progress" ;;
      done)        label="done" ;;
      blocked)     label="blocked" ;;
      *)           label="$stage" ;;
    esac
  fi
  # gh accepts repeated --add-label; idempotent because GitHub silently
  # ignores re-adding the same label.
  gh issue edit "$num" --repo "$repo" --add-label "$label" >/dev/null
}

main() {
  local verb="${1:-}"
  if [ -z "$verb" ]; then
    echo "issue/github.sh: verb required" >&2
    exit 2
  fi
  shift
  case "$verb" in
    fetch)         cmd_fetch        "$@" ;;
    state)         cmd_state        "$@" ;;
    comment-list)  cmd_comment_list "$@" ;;
    create)        cmd_create       "$@" ;;
    transition)    cmd_transition   "$@" ;;
    *)
      echo "issue/github.sh: unknown verb '$verb'" >&2
      exit 2
      ;;
  esac
}

main "$@"
