#!/usr/bin/env bash
# scripts/lib/template_resolve.sh — three-layer template resolution.
# Order (per spec §12):
#   1. [project.<name>.paths].<key>  → file path (abs, or relative to devdoc_dir)
#   2. <devdoc>/templates/<key>.md
#   3. <plugin>/templates/<key>.md
#
# #81: self-sources paths/io/config (DEVAGENT_ROOT from BASH_SOURCE, like
# revision.sh) so the resolver works regardless of how the caller is wired —
# template.sh sources only this file, so config_get_project_field / plugin_root
# would otherwise be undefined and every layer would fail (everything MISSING).

: "${DEVAGENT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/config.sh"

DEVAGENT_TEMPLATE_KEYS=(
  coding_standards
  commit_template
  mr_template
  issue_template-bug
  issue_template-feature
  issue_template-docs
  issue_template-perf
  issue_template-chore
  epic_template
  redteam_issue
  redteam_mr
  imPlan_template
  actualWork_template
  lessonsLearned_template
  wbs_template
  statusreport_template
  checklist-standard
  checklist-perf
  checklist-docs-only
  checklist-research
  revision_block
  intent_template
)

# template_project_paths_override <project> <key>
# Returns the path from [project.<P>.paths].<key>, or empty. Absolute paths are
# used directly; relative paths are taken under the project's devdoc_dir (mirrors
# artifact.sh:21). Tests can short-circuit via TEMPLATE_PATHS_OVERRIDE_<key>.
template_project_paths_override() {
  local project="$1" key="$2"
  local env_name="TEMPLATE_PATHS_OVERRIDE_${key//-/_}"
  if [ -n "${!env_name:-}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  local override
  override="$(config_get_project_field "${project}" "paths.${key}" 2>/dev/null || true)"
  [ -n "${override}" ] || return 0
  if [ "${override#/}" != "${override}" ]; then
    printf '%s\n' "${override}"           # absolute
  else
    local devdoc
    devdoc="$(template_devdoc_dir "${project}")"
    [ -n "${devdoc}" ] && printf '%s/%s\n' "${devdoc%/}" "${override}"
  fi
}

template_devdoc_dir() {
  local project="$1"
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"; return 0
  fi
  config_get_project_field "${project}" "devdoc_dir" 2>/dev/null || true
}

# template_plugin_dir — plugin template dir. #81: derive from plugin_root
# (BASH_SOURCE-based) so it works in prod; keep the env override for tests.
template_plugin_dir() {
  printf '%s\n' "${DEVAGENT_PLUGIN_TEMPLATES:-$(plugin_root)/templates}"
}

# template_resolve <project> <key>
# Prints:
#   path=<absolute path>
#   layer=<project|devdoc|plugin>
# Returns 1 if no layer satisfies.
template_resolve() {
  local project="$1" key="$2"
  local path

  path="$(template_project_paths_override "${project}" "${key}")"
  if [ -n "${path}" ]; then
    if [ -f "${path}" ]; then
      printf 'path=%s\nlayer=project\n' "${path}"
      return 0
    fi
    # #341: configured override present but file missing — warn (naming the dead
    # path), then fall through. Blind spot: a RELATIVE override with devdoc_dir
    # unset collapses to empty in template_project_paths_override, so it reaches
    # here as "no override" and is not warned (devdoc_dir is effectively always
    # configured; artifact.sh's inline warn covers that corner).
    warn "template_resolve: configured override for '${key}' not found: ${path} (falling through to defaults)"
  fi

  local devdoc
  devdoc="$(template_devdoc_dir "${project}")"
  if [ -n "${devdoc}" ]; then
    path="${devdoc%/}/templates/${key}.md"
    if [ -f "${path}" ]; then
      printf 'path=%s\nlayer=devdoc\n' "${path}"
      return 0
    fi
  fi

  path="$(template_plugin_dir)/${key}.md"
  if [ -f "${path}" ]; then
    printf 'path=%s\nlayer=plugin\n' "${path}"
    return 0
  fi

  return 1
}

# template_list <project> — table of all known keys + resolved layer.
template_list() {
  local project="$1"
  local key out
  printf '%-32s %-8s %s\n' "KEY" "LAYER" "PATH"
  for key in "${DEVAGENT_TEMPLATE_KEYS[@]}"; do
    if out="$(template_resolve "${project}" "${key}")"; then
      local p l
      p="$(printf '%s\n' "${out}" | sed -n 's/^path=//p')"
      l="$(printf '%s\n' "${out}" | sed -n 's/^layer=//p')"
      printf '%-32s layer=%-7s %s\n' "${key}" "${l}" "${p}"
    else
      printf '%-32s layer=%-7s %s\n' "${key}" "MISSING" "(none)"
    fi
  done
}

# template_show <project> <key> — print resolved layer banner + file contents.
template_show() {
  local project="$1" key="$2"
  local out p l
  if ! out="$(template_resolve "${project}" "${key}")"; then
    printf 'template_show: no template found for key: %s\n' "${key}" >&2
    return 1
  fi
  p="$(printf '%s\n' "${out}" | sed -n 's/^path=//p')"
  l="$(printf '%s\n' "${out}" | sed -n 's/^layer=//p')"
  printf '# === template %s (layer=%s) ===\n' "${key}" "${l}"
  printf '# source: %s\n\n' "${p}"
  cat "${p}"
}
