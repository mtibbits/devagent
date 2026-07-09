#!/usr/bin/env bash
# scripts/history.sh — entry point for /devagent:history
#
# Forms:
#   history.sh [--project P]                 → all issues in project
#   history.sh [--project P] Issue-NNN       → one issue

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only needs devdoc-dir resolution (#246) — source the config trio directly
# instead of the whole dependency-CRUD library.
# shellcheck source=lib/paths.sh
. "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/io.sh
. "${SCRIPT_DIR}/lib/io.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/history.sh
. "${SCRIPT_DIR}/lib/history.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:history [--project P] [Issue-NNN]
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

# #239: propagate the resolver's die (it exits only the $(...) subshell, leaving
# the parent with DEVDOC="" → a redundant second 'devdoc dir not found:' line).
DEVDOC="$(project_devdoc_dir "${PROJECT}")" || exit 2
# Retained for the distinct configured-but-missing-on-disk case (resolver returns
# a non-empty path with rc 0, so the line above does not fire).
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
