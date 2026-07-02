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
source "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/log.sh"

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
# #124: route the bare-invocation default through the active-project chain
# (arg → DEVAGENT_ACTIVE_PROJECT → global _active.toml → single configured project)
# instead of the literal string 'default', matching next.sh / statusreport.sh / wbs.
PROJECT="$(active_resolve_project "$PROJECT")"

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

# #96: int + str in one transaction.
state_set_many "$PROJECT" int revision "$n_new" str pending_comments_file "$prev_comments"

k=$(grep -c '^### @' "$prev_comments" || true)
# #75: route through log_append so the entry lands inside the `## Log` section,
# not at EOF after the just-appended `## Revision N` block.
log_append "$issue_dir" revise "revision $n_new started, $k comments to address"

printf 'revise: advanced to revision %s (%s comments pending)\n' "$n_new" "$k"

if [[ "$NO_CHAIN" -eq 0 ]]; then
  chain_cmd="${DEVAGENT_CHAIN_CMD:-/devagent:next}"
  if [[ -x "$chain_cmd" ]]; then
    "$chain_cmd" /devagent:next
  else
    printf 'CHAIN: %s\n' "$chain_cmd"
  fi
fi
