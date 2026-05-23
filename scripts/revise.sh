#!/usr/bin/env bash
#
# /devagent:revise — start a new revision pass after MR feedback.
#
# Usage:  revise.sh [project] [issue] [--no-chain]

set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"

die() {
  printf 'revise: %s\n' "$*" >&2
  exit 1
}

state_value() {
  local project="$1" key="$2"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  [[ -f "$state" ]] || return 1
  awk -F'=' -v key="$key" '
    $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$state"
}

state_set() {
  local project="$1" key="$2" value="$3"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local tmp
  tmp="$(mktemp)"
  local found=0
  if [[ -f "$state" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
        printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$state"
  fi
  if [[ $found -eq 0 ]]; then
    printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$state"
}

state_set_int() {
  local project="$1" key="$2" value="$3"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local tmp
  tmp="$(mktemp)"
  local found=0
  if [[ -f "$state" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
        printf '%s = %s\n' "$key" "$value" >>"$tmp"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$state"
  fi
  if [[ $found -eq 0 ]]; then
    printf '%s = %s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$state"
}

# Parse argv
PROJECT=""
ISSUE=""
NO_CHAIN=0
for arg in "$@"; do
  case "$arg" in
    --no-chain) NO_CHAIN=1 ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$arg"
      elif [[ -z "$ISSUE" ]]; then
        ISSUE="$arg"
      fi
      ;;
  esac
done
[[ -n "$PROJECT" ]] || PROJECT="${DEVAGENT_PROJECT:-default}"

issue_dir=$(state_value "$PROJECT" issue_dir) \
  || die "no active_issue for project '$PROJECT'"
[[ -n "$issue_dir" ]] || die "issue_dir empty in state for project '$PROJECT'"

if [[ -n "$ISSUE" ]]; then
  case "$issue_dir" in
    */"$ISSUE") : ;;
    *) die "requested issue '$ISSUE' does not match active issue_dir '$issue_dir'" ;;
  esac
fi

n_cur=$(revision_current "$PROJECT")
prev_rdir=$(revision_dir "$issue_dir" "$n_cur")
prev_comments="$prev_rdir/comments.md"

if [[ ! -f "$prev_comments" ]]; then
  die "missing $prev_comments — run /devagent:comments first"
fi

n_new=$((n_cur + 1))
new_rdir=$(revision_dir "$issue_dir" "$n_new")
mkdir -p "$new_rdir"

revision_block_text "$n_new" >>"$issue_dir/checklist.md"

state_set_int "$PROJECT" revision "$n_new"
state_set "$PROJECT" pending_comments_file "$prev_comments"

k=$(grep -c '^### @' "$prev_comments" || true)
stamp=$(date '+%Y-%m-%d %H:%M')
printf -- '- %s  revise: revision %s started, %s comments to address\n' \
  "$stamp" "$n_new" "$k" >>"$issue_dir/checklist.md"

printf 'revise: advanced to revision %s (%s comments pending)\n' "$n_new" "$k"

if [[ "$NO_CHAIN" -eq 0 ]]; then
  chain_cmd="${DEVAGENT_CHAIN_CMD:-/devagent:next}"
  if [[ -x "$chain_cmd" ]]; then
    "$chain_cmd" /devagent:next
  else
    printf 'CHAIN: %s\n' "$chain_cmd"
  fi
fi
