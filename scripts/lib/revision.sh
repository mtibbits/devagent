#!/usr/bin/env bash
# Revision helpers for devAgent Phase 6.
#
# This file's own functions are read-only (no global mutation). Source-only file:
# do not execute directly. Note: it sources lib/{paths,io,state}.sh (#97) so
# revision_current can read state through the canonical, section-aware layer.

: "${DEVAGENT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# #97: read state through the canonical, section-aware layer instead of a private
# awk reader (paths+io must precede state). Self-sourced so callers that source only
# this file (e.g. revision_lib.bats) still get state_get; sourcing is idempotent.
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/artifact.sh"
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

# revision_block_text <N> [project] — #120: §12 registry with plugin-default
# fallback; return-1 (not die) semantics preserved.
revision_block_text() {
  local n="$1"
  local tmpl
  tmpl="$(artifact_resolve_or "${2:-}" revision_block)"
  if [[ ! -f "$tmpl" ]]; then
    printf 'revision_block_text: template not found: %s\n' "$tmpl" >&2
    return 1
  fi
  sed "s/{{N}}/${n}/g" "$tmpl"
}
