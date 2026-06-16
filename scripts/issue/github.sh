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
  if [ "$#" -ge 3 ]; then shift 3; else shift "$#"; fi
  local args=(--repo "$repo" --title "$title")
  # #89: a non-empty body_file must exist — otherwise gh would file the literal
  # path string as the body. Empty body_file keeps github's inline-body leniency.
  if [ -n "${body_file}" ]; then
    [ -f "${body_file}" ] || { echo "github.sh: body file not found: ${body_file}" >&2; return 2; }
    args+=(--body-file "${body_file}")
  else
    args+=(--body "")
  fi
  # #89: honor repeatable --label (custom.sh contract; gitlab/jira parity) and
  # reject unknown args instead of silently dropping them.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) args+=(--label "${2:?github.sh: --label needs a value}"); shift 2 ;;
      *) echo "github.sh: unknown create arg: $1" >&2; return 2 ;;
    esac
  done
  local out
  # Capture gh's STDOUT only — do NOT add 2>&1 here (unlike the other verbs):
  # gh writes tips/notices/warnings to stderr, and they must not pollute the
  # URL we parse the issue number from below (#27).
  out="$(gh issue create "${args[@]}")" || return
  # gh prints the new issue's URL (…/issues/N); the backend contract (file.sh,
  # gitlab.sh, the mock) is a bare number. Emit the trailing path segment, but
  # fail loudly if it isn't numeric so a future gh output change surfaces
  # instead of silently corrupting filed.toml (the #27 bug class).
  local num="${out##*/}"
  case "$num" in
    ''|*[!0-9]*) echo "github.sh: could not parse issue number from gh output: $out" >&2; return 1 ;;
  esac
  printf '%s\n' "$num"
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
