#!/usr/bin/env bash
# scripts/capture/lib/template.sh — artifact resolution per spec §12.
# Sourced; defines functions only.
# shellcheck shell=bash

# #424: delegate layers 1-3 to the canonical §12 resolver so a configured
# [project.<name>.paths].<key> override (layer 1) is honored and a dead override
# warns — the same registry the #341 wbs-init / #423 statusreport fixes route
# through. The capture-only DEVAGENT_TEMPLATE_OVERRIDE_* env layer stays ABOVE
# config-paths (mirrors template_resolve's own TEMPLATE_PATHS_OVERRIDE_* short-
# circuit). BASH_SOURCE-derived so it works from any CWD (this file defines no
# SCRIPT_DIR); template_resolve.sh self-sources paths/io/config and is idempotent.
# shellcheck source=../../lib/template_resolve.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/template_resolve.sh"

devagent_resolve_template() {
  local name="${1:?template name required}"
  local sanitized="${name//-/_}"
  local override_var="DEVAGENT_TEMPLATE_OVERRIDE_${sanitized}"
  local override="${!override_var:-}"
  if [[ -n "${override}" && -f "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi
  # Layers 1-3 (config-paths → devdoc → plugin) via template_resolve, feeding
  # capture's harness-resolved dirs through the resolver's injection seams as an
  # INLINE prefix (never exported — keeps the seam out of later config lookups /
  # the python child). template_resolve emits `path=…\nlayer=…` on stdout (warn to
  # stderr, which propagates through capture.sh's own $()); extract the bare path so
  # capture.sh's filename contract holds. `if …; then` captures the rc so `set -e`
  # cannot swallow the no-template return below.
  local resolved
  if resolved="$(
    DEVAGENT_TEST_DEVDOC="${DEVAGENT_DEVDOC_DIR:-}" \
    DEVAGENT_PLUGIN_TEMPLATES="${DEVAGENT_PLUGIN_DIR:+${DEVAGENT_PLUGIN_DIR%/}/templates}" \
    template_resolve "${DEVAGENT_PROJECT:-}" "${name}"
  )"; then
    printf '%s\n' "${resolved}" | sed -n 's/^path=//p'
    return 0
  fi
  echo "no such template: ${name}" >&2
  return 2
}
