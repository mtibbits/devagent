#!/usr/bin/env bash
# code/custom.sh — template/stub for a custom code (MR) backend.
# See scripts/issue/custom.sh for the implementation walkthrough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: custom.sh <verb> [args…]
  push-branch <remote> <branch>
  create-mr <repo> <title> <body-file> <head> <base> [--draft]
  mr-state <mr-url>
  mr-comments <mr-url>
  merge-mr <mr-url> [--method squash|merge|rebase]
EOF
  exit 2
}

verb="${1:-}"; shift || true
case "$verb" in
  push-branch|create-mr|mr-state|mr-comments|merge-mr)
    bc_die_not_implemented custom "$verb" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
