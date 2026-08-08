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
usage: checklist-init.sh [--template <name>] [--project <p>] <issue-dir>
   <name>: shipped defaults are standard | docs-only | research | perf
   (default: standard); with a project in scope, any name resolvable via the
   §12 template registry is legal (#120).
   <p>: the project whose template registry applies (#572 — an explicit
   project is a per-invocation scope assertion the guard never questions).
USAGE
  exit 2
}

template=standard
project_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template="$2"; shift 2 ;;
    --project)  project_arg="$2"; shift 2 ;;
    --project=*) project_arg="${1#--project=}"; shift ;;
    -h|--help)  usage ;;
    --)         shift; break ;;
    -*)         usage ;;
    *)          break ;;
  esac
done
[[ $# -eq 1 ]] || usage
issue_dir="$1"

# #120: best-effort project resolution so per-project template overrides
# apply. The containment (2>/dev/null || true) is deliberate — a bare run with
# no config keeps working, plugin default applies. #572: _try form so the
# resolution source is readable, guarded after the site's own tolerance.
active_resolve_project_try "$project_arg" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
active_guard_scope checklist-init
checklist_init "$issue_dir" "$template" "$project"
echo "wrote $issue_dir/checklist.md (template: $template)"
