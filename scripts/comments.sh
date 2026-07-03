#!/usr/bin/env bash
#
# /devagent:comments — fetch MR comments to <issue-dir>/revisions/r<N>/comments.md.
#
# Usage:  comments.sh [project] [issue]
#
# Reads `mr_url` from per-project state, invokes the code backend's
# mr-comments verb, and writes the output without incrementing the
# revision counter. Idempotent: a re-run overwrites the same file.

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

# Private die() preserves the "comments:" prefix; defined after the sources so it
# shadows io.sh's die.
die() {
  printf 'comments: %s\n' "$*" >&2
  exit 1
}

# #97: state reads go through lib/state.sh (state_get) instead of a private
# section-ignorant awk reader. (config_value below reads CONFIG, is section-aware,
# and is out of scope.)

config_value() {
  local project="$1" key="$2"
  local cfg="$HOME/.claude/devagent/config.toml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" "$project" "$key" <<'PY'
import sys, re
cfg, project, key = sys.argv[1], sys.argv[2], sys.argv[3]
section = None
target_section = f"project.{project}.code_source"
target_key = key
with open(cfg) as f:
    for line in f:
        line = line.strip()
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            section = m.group(1)
            continue
        if section == target_section and "=" in line:
            k, _, v = line.partition("=")
            if k.strip() == target_key:
                v = v.strip().strip('"').strip("'")
                print(v)
                sys.exit(0)
sys.exit(1)
PY
}

resolve_project_arg() {
  # #124: route the bare-invocation default through the active-project chain
  # (arg → DEVAGENT_ACTIVE_PROJECT → global _active.toml → single configured
  # project) instead of the literal string 'default', matching next.sh / wbs.
  active_resolve_project "${1:-}"
}

main() {
  local project
  project=$(resolve_project_arg "$@")
  [[ $# -ge 1 ]] && shift || true
  local issue_arg="${1:-}"

  local issue_dir
  issue_dir=$(issue_context_dir "$project" "$issue_arg") \
    || die "no active_issue for project '$project' (state file missing or empty)"
  [[ -n "$issue_dir" ]] || die "issue_dir empty in state for project '$project'"
  [[ -d "$issue_dir" ]] || die "issue dir not found: $issue_dir"
  # (#240 supersedes the #70 crosscheck: an explicit arg IS the issue —
  # mr_url now reads ITS [context] table.)

  local mr_url
  mr_url=$(state_ctx_get "$project" mr_url "$issue_arg") || true
  [[ -n "$mr_url" ]] || die "mr_url not set in state — run /devagent:ship first"

  local n
  n=$(revision_current "$project")

  local rdir
  rdir=$(revision_dir "$issue_dir" "$n")
  mkdir -p "$rdir"

  local out="$rdir/comments.md"

  local backend_cmd="${DEVAGENT_CODE_BACKEND_CMD:-}"
  if [[ -z "$backend_cmd" ]]; then
    local backend
    backend=$(config_value "$project" backend) || die "code_source.backend missing in config"
    backend_cmd="$DEVAGENT_ROOT/scripts/code/${backend}.sh"
    [[ -x "$backend_cmd" ]] || die "backend script not executable: $backend_cmd"
  fi

  local tmp
  tmp="$(mktemp)"
  if ! "$backend_cmd" mr-comments "$mr_url" >"$tmp"; then
    rm -f "$tmp"
    die "backend mr-comments failed for $mr_url"
  fi
  mv "$tmp" "$out"

  local k
  k=$(grep -c '^### @' "$out" || true)

  # #75: route through log_append so the entry lands inside the `## Log` section
  # even when a later `## Revision N` block follows it.
  log_append "$issue_dir" comments "fetched $k comments"

  printf 'comments: wrote %s (%s comments)\n' "$out" "$k"
}

main "$@"
