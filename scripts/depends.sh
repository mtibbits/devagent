#!/usr/bin/env bash
# scripts/depends.sh — entry point for /devagent:depends
#
# Grammar:
#   depends.sh [--project P] <A> on <B>      record A depends on B
#   depends.sh [--project P] list            print graph
#
# Project resolution: --project flag wins; otherwise tries
# DEVAGENT_ACTIVE_PROJECT env var; otherwise errors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"
# #331: state.sh + active.sh for the documented arg→env→pointer→fallback resolver
# (lib/depends.sh already sources paths/io/config).
# shellcheck source=lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/active.sh
. "${SCRIPT_DIR}/lib/active.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:depends [--project P] <A> on <B>
  /devagent:depends [--project P] list

Examples:
  /devagent:depends --project volk Issue-676 on Issue-Fork-12
  /devagent:depends list
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

# #331: documented arg→env→pointer→fallback chain (was env-only).
PROJECT="$(active_resolve_project "${PROJECT}" 2>/dev/null || true)"
if [ -z "${PROJECT}" ]; then
  printf 'depends: no project (pass --project, set DEVAGENT_ACTIVE_PROJECT, or configure one)\n' >&2
  usage
fi

if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

if [ "${ARGS[0]}" = "list" ]; then
  depends_graph "${PROJECT}"
  exit 0
fi

if [ "${#ARGS[@]}" -ne 3 ] || [ "${ARGS[1]}" != "on" ]; then
  printf 'depends: expected "<A> on <B>" got: %s\n' "${ARGS[*]}" >&2
  usage
fi

A="${ARGS[0]}"
B="${ARGS[2]}"
if depends_add "${PROJECT}" "${A}" "${B}"; then
  printf 'recorded: %s depends on %s\n' "${A}" "${B}"
else
  exit $?
fi
