#!/usr/bin/env bash
#
# /devagent:revise — start a new revision pass after MR feedback.
#
# Usage:  revise.sh [project] [issue] [--no-chain]

set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"

# Private die() preserves the "revise:" message prefix; defined after the sources so
# it shadows io.sh's die (state.sh's internal die calls then carry this prefix too).
die() {
  printf 'revise: %s\n' "$*" >&2
  exit 1
}

# #97: state read/write now goes through lib/state.sh (state_get / state_set /
# state_set_int). The private section-ignorant helpers that appended a not-found key
# at EOF — corrupting the [parked] table — have been removed.

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

issue_dir=$(state_get "$PROJECT" issue_dir) \
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
