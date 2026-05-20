#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"

usage() {
  cat <<USAGE
usage: checklist-init.sh [--template <name>] <issue-dir>
   <name> one of: standard | docs-only | research | perf  (default: standard)
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

checklist_init "$issue_dir" "$template"
echo "wrote $issue_dir/checklist.md (template: $template)"
