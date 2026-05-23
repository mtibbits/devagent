#!/usr/bin/env bash
# Scaffold <devdoc>/WBS.md from templates/wbs_template.md, substituting
# {{PROJECT}}. Refuses to overwrite unless --force.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
devagent_load_config

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) devagent_log warn "wbs init: ignoring unknown arg '$arg'" ;;
  esac
done

dest="$DEVAGENT_DEVDOC_DIR/WBS.md"

if [[ -e "$dest" && $force -ne 1 ]]; then
  devagent_log err "wbs init: $dest exists; pass --force to overwrite"
  exit 1
fi

# Resolve template per spec §12 artifact-resolution order:
# 1. <devdoc>/templates/wbs_template.md
# 2. plugin templates/wbs_template.md
template=""
for candidate in \
  "$DEVAGENT_DEVDOC_DIR/templates/wbs_template.md" \
  "$PLUGIN_ROOT/templates/wbs_template.md"; do
  if [[ -f "$candidate" ]]; then
    template="$candidate"
    break
  fi
done
: "${template:?no wbs_template.md found in devdoc or plugin}"

mkdir -p "$(dirname "$dest")"
sed -e "s|{{PROJECT}}|${DEVAGENT_PROJECT}|g" "$template" > "$dest"
devagent_log info "wbs init: wrote $dest from $template"
