#!/usr/bin/env bash
# scripts/lib/template_resolve.sh — three-layer template resolution.
# Order (per spec §12):
#   1. [project.<name>.paths].<key>  → file path
#   2. <devdoc>/templates/<key>.md
#   3. <plugin>/templates/<key>.md   (DEVAGENT_PLUGIN_TEMPLATES env)

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
)

# template_project_paths_override <project> <key>
# Returns absolute path from [project.<P>.paths].<key>, or empty.
# Tests can short-circuit via TEMPLATE_PATHS_OVERRIDE_<key> env var.
template_project_paths_override() {
  local project="$1" key="$2"
  local env_name="TEMPLATE_PATHS_OVERRIDE_${key//-/_}"
  if [ -n "${!env_name:-}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  if command -v config_get_project_paths_field >/dev/null 2>&1; then
    config_get_project_paths_field "${project}" "${key}" || true
  fi
}

template_devdoc_dir() {
  local project="$1"
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"; return 0
  fi
  if command -v config_get_project_field >/dev/null 2>&1; then
    config_get_project_field "${project}" "devdoc_dir"
    return 0
  fi
  printf '%s/devdoc\n' "${HOME}"
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
  if [ -n "${path}" ] && [ -f "${path}" ]; then
    printf 'path=%s\nlayer=project\n' "${path}"
    return 0
  fi

  local devdoc
  devdoc="$(template_devdoc_dir "${project}")"
  path="${devdoc}/templates/${key}.md"
  if [ -f "${path}" ]; then
    printf 'path=%s\nlayer=devdoc\n' "${path}"
    return 0
  fi

  path="${DEVAGENT_PLUGIN_TEMPLATES:-${DEVAGENT_REPO_ROOT:-}/templates}/${key}.md"
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
