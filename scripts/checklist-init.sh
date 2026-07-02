#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/config.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
source "$PLUGIN_ROOT/scripts/lib/active.sh"
source "$PLUGIN_ROOT/scripts/lib/artifact.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

usage() {
  cat <<USAGE
usage: checklist-init.sh [--template <name>] <issue-dir>
   <name>: shipped defaults are standard | docs-only | research | perf
   (default: standard); with a project in scope, any name resolvable via the
   §12 template registry is legal (#120).
USAGE
  exit 2
}

template=standard
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template="$2"; shift 2 ;;
    -h|--help)  usage ;;
    --)         shift; break ;;
    -*)         usage ;;
    *)          break ;;
  esac
done
[[ $# -eq 1 ]] || usage
issue_dir="$1"

# #120: best-effort project resolution so per-project template overrides
# apply. The echo wrapper in $() is deliberate — its die exits the SUBSHELL
# only (a bare run with no config keeps working, plugin default applies).
project="$(active_resolve_project '' 2>/dev/null || true)"
checklist_init "$issue_dir" "$template" "$project"
echo "wrote $issue_dir/checklist.md (template: $template)"
