#!/usr/bin/env bash
# scripts/grep.sh — entry point for /devagent:grep
#
# Greps across per-issue artifact files only (no Captures by default).
# Output: <issue-dir>:<file>:<line-num>: <matching-line>
#
# Supports -i and -l flag pass-through (standard grep semantics).
# Adds --captures to also search <devdoc>/Captures/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"  # for _depends_devdoc_dir

ARTIFACT_FILES=(
  "issue.md"
  "imPlan.md"
  "imPlan-potentialFutureEnhancements.md"
  "actualWork.md"
  "mr.md"
  "checklist.md"
)

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:grep [project] [-i] [-l] [--captures] <pattern>

Searches: issue.md, imPlan.md, imPlan-potentialFutureEnhancements.md,
          actualWork.md, mr.md, checklist.md across all issue dirs.

Output: <issue-dir>:<file>:<line-num>: <matching-line>
EOF
  exit 2
}

PROJECT=""
GREP_OPTS=()
INCLUDE_CAPTURES=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --captures) INCLUDE_CAPTURES=1; shift ;;
    -i|-l|-iL|-li) GREP_OPTS+=("$1"); shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) GREP_OPTS+=("$1"); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'grep: no project specified and DEVAGENT_ACTIVE_PROJECT unset\n' >&2
  usage
fi
if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

PATTERN="${ARGS[0]}"

DEVDOC="$(_depends_devdoc_dir "${PROJECT}")"
if [ ! -d "${DEVDOC}" ]; then
  printf 'grep: devdoc dir not found: %s\n' "${DEVDOC}" >&2
  exit 2
fi

INCLUDES=()
for f in "${ARTIFACT_FILES[@]}"; do
  INCLUDES+=(--include="${f}")
done

EXCLUDES=(--exclude-dir=Captures --exclude-dir=templates --exclude-dir=StatusReports)

# Pass 1: artifact files in issue dirs (Captures always excluded here).
grep -RnH "${GREP_OPTS[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" -- \
  "${PATTERN}" "${DEVDOC}"
rc=$?

# Pass 2: captures (all *.md under <devdoc>/Captures/).
if [ "${INCLUDE_CAPTURES}" -eq 1 ] && [ -d "${DEVDOC}/Captures" ]; then
  grep -RnH "${GREP_OPTS[@]}" --include='*.md' -- \
    "${PATTERN}" "${DEVDOC}/Captures"
  cap_rc=$?
  # Combine exit codes: 0 if either found, 1 if neither, 2 stays 2.
  if [ "${rc}" -ne 0 ] && [ "${cap_rc}" -eq 0 ]; then
    rc=0
  fi
fi
exit "${rc}"
