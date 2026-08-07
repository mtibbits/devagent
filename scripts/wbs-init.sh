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
# shellcheck source=lib/state.sh — active_guard_scope reads state_get (#572);
# without it the guard's state lookup would 127 inside its $(... || true)
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"
# shellcheck source=lib/template_resolve.sh
source "$SCRIPT_DIR/lib/template_resolve.sh"

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

active_resolve_project_try "$project_arg"
project="$ACTIVE_RESOLVED_PROJECT"
config_is_project "$project" || die "wbs init: unknown project '$project'"
active_guard_scope "wbs init"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs init: devdoc_dir not configured for $project"

dest="$devdoc_dir/WBS.md"

if [[ -e "$dest" && $force -ne 1 ]]; then
  die "wbs init: $dest exists; pass --force to overwrite"
fi

# Resolve the template through the §12 registry (lib/template_resolve.sh) so a
# [project.<name>.paths].wbs_template override (layer 1) is honored — not just
# devdoc (2) / plugin (3), which the previous hand-rolled loop was limited to.
# #341. The `if …; then` captures the rc so `set -e` cannot swallow the die on a
# genuine no-template case (template_resolve returns 1 when no layer matches).
template=""
if resolved="$(template_resolve "$project" wbs_template)"; then
  template="$(printf '%s\n' "$resolved" | sed -n 's/^path=//p')"
fi
[[ -n "$template" ]] || die "no wbs_template.md found for '$project' (checked project paths, devdoc, plugin)"

mkdir -p "$(dirname "$dest")"
sed -e "s|{{PROJECT}}|${project}|g" "$template" > "$dest"
info "wbs init: wrote $dest from $template"
