#!/usr/bin/env bash
# /devagent:wbs dispatcher. Routes subcommand to wbs-<sub>.sh.
#
# Project resolution: each subcommand resolves the project via
# active_resolve_project (arg -> env -> global pointer -> single-config).
# The dispatcher itself doesn't resolve; it just routes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: /devagent:wbs <init|update|show> [project] [args]

  init [--force]                        scaffold <devdoc>/WBS.md
  update                                append/update entries from active issues
  show [--depth N] [--milestone X]      render WBS markdown (filtered)
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift

case "$sub" in
  init)   exec bash "$SCRIPT_DIR/wbs-init.sh"   "$@" ;;
  update) exec bash "$SCRIPT_DIR/wbs-update.sh" "$@" ;;
  show)   exec bash "$SCRIPT_DIR/wbs-show.sh"   "$@" ;;
  *)      usage ;;
esac
