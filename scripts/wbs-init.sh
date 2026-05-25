#!/usr/bin/env bash
# Scaffold <devdoc>/WBS.md from templates/wbs_template.md, substituting
# {{PROJECT}}. Refuses to overwrite unless --force.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"

force=0
project_arg=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --*) warn "wbs init: ignoring unknown flag '$arg'" ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$arg"
      else
        warn "wbs init: ignoring extra arg '$arg'"
      fi
      ;;
  esac
done

project="$(active_resolve_project "$project_arg")"
config_is_project "$project" || die "wbs init: unknown project '$project'"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs init: devdoc_dir not configured for $project"

dest="$devdoc_dir/WBS.md"

if [[ -e "$dest" && $force -ne 1 ]]; then
  die "wbs init: $dest exists; pass --force to overwrite"
fi

# Resolve template per spec §12 artifact-resolution order:
# 1. <devdoc>/templates/wbs_template.md
# 2. plugin templates/wbs_template.md
template=""
for candidate in \
  "$devdoc_dir/templates/wbs_template.md" \
  "$PLUGIN_ROOT/templates/wbs_template.md"; do
  if [[ -f "$candidate" ]]; then
    template="$candidate"
    break
  fi
done
[[ -n "$template" ]] || die "no wbs_template.md found in devdoc or plugin"

mkdir -p "$(dirname "$dest")"
sed -e "s|{{PROJECT}}|${project}|g" "$template" > "$dest"
info "wbs init: wrote $dest from $template"
