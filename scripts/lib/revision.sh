#!/usr/bin/env bash
# Revision helpers for devAgent Phase 6.
#
# All functions are pure (no global mutation). Source-only file: do not
# execute directly.

: "${DEVAGENT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# #97: read state through the canonical, section-aware layer instead of a private
# awk reader (paths+io must precede state). Self-sourced so callers that source only
# this file (e.g. revision_lib.bats) still get state_get; sourcing is idempotent.
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/state.sh"

# revision_current <project>
revision_current() {
  local project="$1"
  local n
  n="$(state_get "$project" revision 2>/dev/null || true)"
  [[ -n "$n" ]] || n=1
  printf '%s\n' "$n"
}

# revision_dir <issue-dir> <N>
revision_dir() {
  local issue_dir="$1"
  local n="$2"
  printf '%s/revisions/r%s\n' "$issue_dir" "$n"
}

# revision_block_text <N>
revision_block_text() {
  local n="$1"
  local tmpl="$DEVAGENT_ROOT/templates/revision_block.md"
  if [[ ! -f "$tmpl" ]]; then
    printf 'revision_block_text: template not found: %s\n' "$tmpl" >&2
    return 1
  fi
  sed "s/{{N}}/${n}/g" "$tmpl"
}
