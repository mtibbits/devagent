#!/usr/bin/env bash
# /devagent:wbs dispatcher. Routes subcommand to wbs-<sub>.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
devagent_load_config

usage() {
  cat >&2 <<'EOF'
usage: /devagent:wbs <init|update|show> [args]

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
