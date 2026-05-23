#!/usr/bin/env bash
# scripts/capture/lib/template.sh — artifact resolution per spec §12.
# Sourced; defines functions only.
# shellcheck shell=bash

devagent_resolve_template() {
  local name="${1:?template name required}"
  local sanitized="${name//-/_}"
  local override_var="DEVAGENT_TEMPLATE_OVERRIDE_${sanitized}"
  local override="${!override_var:-}"
  if [[ -n "${override}" && -f "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi
  if [[ -n "${DEVAGENT_DEVDOC_DIR:-}" ]]; then
    local devdoc_path="${DEVAGENT_DEVDOC_DIR%/}/templates/${name}.md"
    if [[ -f "${devdoc_path}" ]]; then
      printf '%s\n' "${devdoc_path}"
      return 0
    fi
  fi
  if [[ -n "${DEVAGENT_PLUGIN_DIR:-}" ]]; then
    local plugin_path="${DEVAGENT_PLUGIN_DIR%/}/templates/${name}.md"
    if [[ -f "${plugin_path}" ]]; then
      printf '%s\n' "${plugin_path}"
      return 0
    fi
  fi
  echo "no such template: ${name}" >&2
  return 2
}
