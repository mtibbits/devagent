#!/usr/bin/env bash
# scripts/issue/github.sh — GitHub issue backend.
# Plan 2 implements only the `fetch` verb. Other verbs land in later plans.
# Spec §9.1 (contract), §9.3 (markdown shape).

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

  # Render with jq into the spec §9.3 shape.
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

main() {
  local verb="${1:-}"
  shift || true
  case "$verb" in
    fetch)        cmd_fetch "$@" ;;
    create|transition|state|comment-list)
      echo "issue/github.sh: '$verb' not implemented in Plan 2 (lands in later plan)" >&2
      exit 64
      ;;
    *)
      echo "issue/github.sh: unknown verb '${verb:-<none>}'" >&2
      exit 64
      ;;
  esac
}

main "$@"
