#!/usr/bin/env bash
# scripts/lib/artifact.sh — resolve artifact template paths per spec §12.
# Resolution order:
#   1. [project.<name>.paths].<artifact_key>      (absolute or relative to devdoc_dir)
#   2. <devdoc>/templates/<name>.md
#   3. $(plugin_root)/templates/<name>.md
#
# Public: artifact_resolve <project> <artifact_key>
#   echoes the resolved path on stdout, returns 0 on success, 1 if no match.
# Requires paths.sh, io.sh, config.sh sourced first by the caller.

artifact_resolve() {
  local project="$1" key="$2"
  [[ -n "$project" && -n "$key" ]] || {
    echo "artifact_resolve: project+key required" >&2
    return 2
  }

  # 1. project-specific override under [project.<name>.paths]
  local override
  override="$(config_get_project_field "$project" "paths.$key" 2>/dev/null || true)"
  if [[ -n "$override" ]]; then
    if [[ "$override" = /* ]]; then
      [[ -f "$override" ]] && { echo "$override"; return 0; }
    else
      local devdoc
      devdoc="$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)"
      if [[ -n "$devdoc" && -f "${devdoc%/}/$override" ]]; then
        echo "${devdoc%/}/$override"; return 0
      fi
    fi
  fi

  # 2. devdoc-level template
  local devdoc devdoc_path
  devdoc="$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)"
  if [[ -n "$devdoc" ]]; then
    devdoc_path="${devdoc%/}/templates/${key}.md"
    [[ -f "$devdoc_path" ]] && { echo "$devdoc_path"; return 0; }
  fi

  # 3. plugin default
  local plugin_path
  plugin_path="$(plugin_root)/templates/${key}.md"
  [[ -f "$plugin_path" ]] && { echo "$plugin_path"; return 0; }

  return 1
}
