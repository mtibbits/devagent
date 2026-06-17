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
  local val
  # Preserve config_get's exit code so callers' `|| true` / `|| echo <fallback>`
  # still fire on a missing field (#82).
  val="$(config_get "project.${project}.${field}")" || return $?
  # #82: path-typed fields are tilde-expanded at the source, so every consumer
  # gets a usable path (previously left literal at 21 call sites). This whitelist
  # is the single source of truth for which project fields are filesystem paths.
  case "$field" in
    source_dir|devdoc_dir|worktree_root|build_dir|paths.*)
      expand_tilde "$val" ;;
    *)
      printf '%s\n' "$val" ;;
  esac
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

# step_models_tier <project> <step-num>
# #150: advisory only. Echoes the model tier for a workflow step from the optional
# [project.<name>.step_models] table, or returns 1 (prints nothing) when no tier
# resolves — so an absent table yields byte-identical output to before.
# Resolution: a per-step override (step_models.<N>) wins over the step's class.
# The step→class map is fixed (advisory): thinking = 1 7 8 9 12, checking = 3 13 14,
# everything else = default. A class with no tier set falls back to the default tier.
step_models_tier() {
  local project="$1" step="$2" tier=""
  [[ -n "$project" && -n "$step" ]] || return 1
  # 1. per-step override wins
  tier="$(config_get_project_field "$project" "step_models.${step}" 2>/dev/null || true)"
  if [[ -z "$tier" ]]; then
    # 2. class tier (fixed step→class map)
    local class="default"
    # shellcheck disable=SC2194 # constant subject; space-padded membership test
    case " 1 7 8 9 12 " in *" $step "*) class="thinking" ;; esac
    # shellcheck disable=SC2194 # constant subject; space-padded membership test
    case " 3 13 14 "    in *" $step "*) class="checking" ;; esac
    tier="$(config_get_project_field "$project" "step_models.${class}" 2>/dev/null || true)"
    # 3. fall back to the default tier when the class tier is unset
    if [[ -z "$tier" && "$class" != "default" ]]; then
      tier="$(config_get_project_field "$project" "step_models.default" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$tier" ]] || return 1
  printf '%s\n' "$tier"
}
