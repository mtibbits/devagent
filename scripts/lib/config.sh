#!/usr/bin/env bash
# scripts/lib/config.sh — read ~/.claude/devagent/config.toml.
# Requires paths.sh and io.sh sourced first.

_config_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

config_load() {
  local f
  f="$(config_path)"
  [[ -f "$f" ]] || die "config not found at $f (run /devagent:init <project>)"
  _config_toml validate "$f" || die "config at $f is not valid TOML"
}

config_get() {
  local key="$1"
  _config_toml get "$(config_path)" "$key"
}

config_get_default() {
  config_get "defaults.$1"
}

config_get_project_field() {
  local project="$1" field="$2"
  [[ -n "$project" && -n "$field" ]] || {
    echo "config_get_project_field: project and field required" >&2
    return 2
  }
  config_get "project.${project}.${field}"
}

config_list_projects() {
  _config_toml list-tables "$(config_path)" \
    | awk -F. '$1=="project" && NF==2 { print $2 }'
}

config_is_project() {
  local target="$1" p
  while IFS= read -r p; do
    [[ "$p" == "$target" ]] && return 0
  done < <(config_list_projects)
  return 1
}

# Guard for entry-point scripts: if the project is unknown, print a recovery
# menu (configured projects + init suggestion) and exit 1. Reusable across
# scripts that take a project as their first argument.
config_require_project() {
  local project="$1"
  if config_is_project "$project"; then return 0; fi

  echo "error: project '$project' not found in config.toml." >&2
  echo "" >&2

  local configured n
  configured="$(config_list_projects 2>/dev/null || true)"
  n="$(echo "$configured" | wc -w)"
  if [ "$n" -eq 1 ]; then
    echo "  hint: did you mean '$configured'?" >&2
  elif [ "$n" -gt 1 ]; then
    echo "  configured projects: $(echo "$configured" | tr '\n' ' ')" >&2
  fi
  echo "" >&2
  echo "  to add '$project': /devagent:init $project" >&2
  exit 1
}

config_active_project() {
  local count=0 only=""
  local p
  while IFS= read -r p; do
    count=$((count + 1))
    only="$p"
  done < <(config_list_projects)
  if (( count == 1 )); then
    echo "$only"
    return 0
  fi
  die "config_active_project: $count projects configured; pass project explicitly"
}
