#!/usr/bin/env bash
# scripts/history.sh — entry point for /devagent:history
#
# Forms:
#   history.sh [--project P]                 → all issues in project
#   history.sh [--project P] Issue-NNN       → one issue

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"
# shellcheck source=lib/history.sh
. "${SCRIPT_DIR}/lib/history.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:history [project] [Issue-NNN]
EOF
  exit 2
}

PROJECT=""
ISSUE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    -h|--help) usage ;;
    Issue-*) ISSUE="$1"; shift ;;
    *) ISSUE="$1"; shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'history: no project specified\n' >&2
  usage
fi

DEVDOC="$(_depends_devdoc_dir "${PROJECT}")"
if [ ! -d "${DEVDOC}" ]; then
  printf 'history: devdoc dir not found: %s\n' "${DEVDOC}" >&2
  exit 2
fi

format_rows() {
  awk -F'|' '{ printf "%s  %-14s  %s: %s\n", $1, $2, $3, $4 }'
}

if [ -n "${ISSUE}" ]; then
  history_issue "${DEVDOC}/${ISSUE}" | format_rows
else
  history_project "${DEVDOC}" | format_rows
fi
