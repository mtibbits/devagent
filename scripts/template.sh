#!/usr/bin/env bash
# scripts/template.sh — entry point for /devagent:template
#
# Subcommands:
#   list                 print resolution table for all known keys
#   show <key>           print resolved content with layer banner

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/template_resolve.sh
. "${SCRIPT_DIR}/lib/template_resolve.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:template [project] list
  /devagent:template [project] show <key>
EOF
  exit 2
}

PROJECT=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'template: no project specified\n' >&2
  usage
fi
if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

case "${ARGS[0]}" in
  list)
    template_list "${PROJECT}"
    ;;
  show)
    if [ "${#ARGS[@]}" -lt 2 ]; then
      printf 'template show: <key> required\n' >&2
      usage
    fi
    template_show "${PROJECT}" "${ARGS[1]}"
    ;;
  *)
    printf 'template: unknown subcommand: %s\n' "${ARGS[0]}" >&2
    usage
    ;;
esac
