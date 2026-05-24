#!/usr/bin/env bash
# issue/custom.sh — template/stub for a custom issue backend.
#
# To implement your own backend:
#   1. Copy this file to scripts/issue/<yourname>.sh
#   2. Set `backend = "<yourname>"` under [project.<name>.issue_source]
#      in ~/.claude/devagent/config.toml
#   3. Replace each cmd_* function with your implementation.
#   4. Run `bats tests/backend-contract.bats` against your backend
#      to confirm contract compliance (see README "Custom backends").
#
# All five verbs MUST be implemented for the dispatcher to function;
# until they are, each exits 78 (EX_CONFIG) with a documented message
# so callers can report "backend not implemented" cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: custom.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage>
  state <repo> <num>
  comment-list <repo> <num>
EOF
  exit 2
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch|create|transition|state|comment-list)
    bc_die_not_implemented custom "$verb" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
