#!/usr/bin/env bash
# scripts/portfolio.sh — #726. Write one portfolio document (schema v1.2,
# docs/portfolio-schema.md) over every configured project's WBS.md.
# Usage: portfolio.sh [--out PATH | --ready]
#
# --ready (#727) builds the same document in memory and prints one TSV line
# per ready leaf (project, issue, est, text) instead of writing it.
#
# Read-only over every devdoc: it writes the one document and nothing else (no
# WBS.md, no state, no devdoc file); under --ready it writes nothing at all.
# It acts on no single issue and calls no tracker or code host, so it is not a
# trust or resolver entry point, like status.sh. The default output sits under
# devagent's home, outside every devdoc and checkout: the document names
# private projects, and cleanup publishes whatever lies under a devdoc_dir.
#
# The projects reach scripts/lib/portfolio.py as indexed environment variables
# (PORTFOLIO_PROJECT_COUNT, PORTFOLIO_NAME_<i>, and PORTFOLIO_DEVDOC_<i>,
# PORTFOLIO_SOURCE_<i>, PORTFOLIO_WORKTREE_<i> when configured), so no path can
# collide with a delimiter. #890 adds PORTFOLIO_MODEL_THINKING_<i>,
# PORTFOLIO_MODEL_CHECKING_<i> and PORTFOLIO_MODEL_DEFAULT_<i>, the project's
# raw step_models.thinking/.checking/.default (set when the key exists, even
# empty; a key whose value is not a string, e.g. a table, is exported as
# <unreadable>), which the per-leaf `models` field falls back to. Each
# project's own devdoc_dir is read: never the test-only override that maps
# every project to one devdoc.
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
if [[ -n "$ready" ]]; then
  args=(ready)
else
  args=(build --out "${out:-$(devagent_home)/portfolio/portfolio.json}")
fi

cfg="$(config_path)"
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
  # Stderr-quiet, as step_models_tier reads them. With no step_models table no
  # key exists, so the table is probed first. list-keys of the table names its
  # scalar and array keys; _toml.py get exits 1 on an array of tables, and a
  # sub-table is not listed but list-keys of it succeeds. Either is exported
  # as <unreadable>.
  if model_keys="$(_config_toml list-keys "$cfg" "project.$p.step_models" 2>/dev/null)"; then
    for pair in thinking:THINKING checking:CHECKING default:DEFAULT; do
      key="${pair%%:*}"
      var="PORTFOLIO_MODEL_${pair##*:}_$i"
      if grep -Fxq -- "$key" <<< "$model_keys"; then
        if v="$(config_get_project_field "$p" "step_models.$key" 2>/dev/null)"; then
          export "$var=$v"
        else
          rc=$?
          [[ $rc -eq 1 ]] || die "cannot read step_models.$key of project '$p' (rc $rc)"
          export "$var=<unreadable>"
        fi
      elif _config_toml list-keys "$cfg" "project.$p.step_models.$key" > /dev/null 2>&1; then
        export "$var=<unreadable>"
      fi
    done
  fi
  i=$((i + 1))
done <<< "$list"
export PORTFOLIO_PROJECT_COUNT="$i"

exec python3 "$PLUGIN_ROOT/scripts/lib/portfolio.py" "${args[@]}"
