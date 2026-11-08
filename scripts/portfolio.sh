#!/usr/bin/env bash
# scripts/portfolio.sh — #726. Write one portfolio document (schema v1.1,
# docs/portfolio-schema.md) over every configured project's WBS.md.
# Usage: portfolio.sh [--out PATH | --ready]
#
# --ready (#727) builds the same document in memory and prints one TSV line
# per ready leaf (project, issue, est, text) instead of writing it.
#
# Read-only over every devdoc: it writes the one document and nothing else (no
# WBS.md, no state, no devdoc file); under --ready it writes nothing at all. It acts on no single issue and calls no
# tracker or code host, so it is not a trust or resolver entry point, like
# status.sh. The default output sits under devagent's home, outside every
# devdoc and checkout: the document names private projects, and cleanup
# publishes whatever lies under a devdoc_dir.
#
# The projects reach scripts/lib/portfolio.py as indexed environment variables
# (PORTFOLIO_PROJECT_COUNT, PORTFOLIO_NAME_<i>, and PORTFOLIO_DEVDOC_<i>,
# PORTFOLIO_SOURCE_<i>, PORTFOLIO_WORKTREE_<i> when configured), so no path can
# collide with a delimiter. Each project's own devdoc_dir is read: never the
# test-only override that maps every project to one devdoc.
#
# Exit: 0 written (or printed, under --ready); 1 config missing or invalid;
# 2 usage error (--ready with --out included), refused path, or unwritable
# path; 3 self-check failed, nothing written or printed.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"

USAGE="usage: portfolio.sh [--out PATH | --ready]"

usage_error() {
  [[ -n "${1:-}" ]] && echo "portfolio: $1" >&2
  echo "$USAGE" >&2
  exit 2
}

out=""
ready=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    --out)
      [[ -n "${2:-}" ]] || usage_error "--out needs a path"
      out="$2"
      shift 2
      ;;
    --out=*)
      out="${1#--out=}"
      [[ -n "$out" ]] || usage_error "--out needs a path"
      shift
      ;;
    --ready)
      ready=1
      shift
      ;;
    --*)
      usage_error "unknown flag '$1'"
      ;;
    *)
      usage_error "unexpected argument '$1'"
      ;;
  esac
done
[[ -n "$ready" && -n "$out" ]] && usage_error "--ready writes no document; drop --out"

config_load
# The manifest is this script's alone: an inherited PORTFOLIO_* var would fill a gap.
unset "${!PORTFOLIO_@}"
list="$(config_list_projects)" || die "cannot list the projects in $(config_path)"
if [[ -z "$ready" ]]; then
  [[ -n "$out" ]] || out="$(devagent_home)/portfolio/portfolio.json"
fi

i=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  export "PORTFOLIO_NAME_$i=$p"
  for pair in devdoc_dir:DEVDOC source_dir:SOURCE worktree_root:WORKTREE; do
    field="${pair%%:*}"
    var="PORTFOLIO_${pair##*:}_$i"
    if v="$(config_get_project_field "$p" "$field")"; then
      export "$var=$v"
    else
      rc=$?
      [[ $rc -eq 1 ]] || die "cannot read $field of project '$p' (rc $rc)"
    fi
  done
  i=$((i + 1))
done <<< "$list"
export PORTFOLIO_PROJECT_COUNT="$i"

if [[ -n "$ready" ]]; then
  exec python3 "$PLUGIN_ROOT/scripts/lib/portfolio.py" ready
fi
exec python3 "$PLUGIN_ROOT/scripts/lib/portfolio.py" build --out "$out"
