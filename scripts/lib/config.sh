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

# step_models_tier <project> <step-num> [issue_dir]
# #150 surfacing + #151 dispatch consumer. Echoes the model tier for a workflow
# step from the optional [project.<name>.step_models] table, or returns 1
# (prints nothing) when no tier
# resolves — so an absent table yields byte-identical output to before.
# Resolution: a per-issue marker (#291, checking-class steps only) wins over
# the whole table; then a per-step override (step_models.<N>) wins over the
# step's class. The step→class map is fixed (canonical step numbers):
# thinking = 1 7 8 9 12, checking = 3 13 14 21, everything else = default.
# A class with no tier set falls back to the default tier.
#
# Per-issue marker (#291): <issue_dir>/.devagent-step-models holds ONE tier
# token. Like .devagent-baseline (#162) it must not fall back silently — an
# empty or non-token marker dies. The reserved token `inherit` forces
# session-model inheritance (return 1, distinct stderr note), escaping a
# project `checking` pin. Provenance goes to stderr; stdout stays a bare tier.
step_models_tier() {
  local project="$1" step="$2" issue_dir="${3:-}" tier=""
  [[ -n "$project" && -n "$step" ]] || return 1
  # Fixed step→class map — computed once; the per-issue layer is gated on it.
  local class="default"
  # shellcheck disable=SC2194 # constant subject; space-padded membership test
  case " 1 7 8 9 12 " in *" $step "*) class="thinking" ;; esac
  # shellcheck disable=SC2194 # constant subject; space-padded membership test
  case " 3 13 14 21 " in *" $step "*) class="checking" ;; esac
  # 0. per-issue marker (checking class only)
  local marker="${issue_dir%/}/.devagent-step-models"
  if [[ "$class" == "checking" && -n "$issue_dir" && -e "$marker" ]]; then
    # An existing marker that cannot be read as a file must not silently
    # fall back to the project tier (AC3's silent-wrong-tier class).
    [[ -f "$marker" ]] || die "step_models_tier: $marker exists but is not a regular file"
    [[ -r "$marker" ]] || die "step_models_tier: $marker exists but is not readable"
  fi
  if [[ "$class" == "checking" && -n "$issue_dir" && -r "$marker" ]]; then
    local raw
    raw="$(cat "$marker")"
    # One token, nothing else: reject BEFORE stripping so `fable opus` cannot
    # collapse into a plausible-looking `fableopus`.
    tier="$(tr -d '[:space:]' <<<"$raw")"
    [[ -n "$tier" ]] || die "step_models_tier: $marker is empty (no tier token)"
    [[ "$raw" =~ ^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*$ ]] \
      || die "step_models_tier: $marker must hold exactly one tier token (allowed: A-Za-z0-9 . _ -), got: '$raw'"
    if [[ "$tier" == "inherit" ]]; then
      echo "step_models_tier: per-issue 'inherit' from $marker — forcing session-model inheritance" >&2
      return 1
    fi
    echo "step_models_tier: per-issue tier '$tier' from $marker" >&2
    printf '%s\n' "$tier"
    return 0
  fi
  # 1. per-step override wins
  tier="$(config_get_project_field "$project" "step_models.${step}" 2>/dev/null || true)"
  if [[ -z "$tier" ]]; then
    # 2. class tier
    tier="$(config_get_project_field "$project" "step_models.${class}" 2>/dev/null || true)"
    # 3. fall back to the default tier when the class tier is unset
    if [[ -z "$tier" && "$class" != "default" ]]; then
      tier="$(config_get_project_field "$project" "step_models.default" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$tier" ]] || return 1
  printf '%s\n' "$tier"
}

# issue_dir_for <project> <issue> — derive an issue's devdoc directory (#240).
# Byte-matches pull.sh's stored value: ${devdoc%/}/<issue>. Dies loudly via
# project_devdoc_dir when devdoc_dir is unresolvable; display readers that
# must tolerate misconfiguration wrap with 2>/dev/null || true (their existing
# idiom). Pinned sessions derive instead of reading the shared issue_dir slot.
issue_dir_for() {
  local project="$1" issue="$2" devdoc
  [ -n "$issue" ] || die "issue_dir_for: issue required"
  devdoc="$(project_devdoc_dir "$project")"
  printf '%s/%s\n' "${devdoc%/}" "$issue"
}

# project_devdoc_dir <project> — resolve a project's devdoc directory, or die
# loudly (#246; logic moved here from the former depends.sh:_depends_devdoc_dir).
# The DEVAGENT_TEST_DEVDOC override is the one legitimately-optional (tolerant)
# leg; otherwise the path is genuinely required by every caller (ship preflight,
# grep.sh, history.sh), so #78 fails loud instead of the old silent $HOME/devdoc
# fallback. config_get_project_field already returns non-zero on a missing field
# (#82), which we no longer mask. Requires io.sh (die) sourced by the caller.
project_devdoc_dir() {
  local project="$1"
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"
    return 0
  fi
  local devdoc
  devdoc="$(config_get_project_field "${project}" "devdoc_dir")" \
    || die "cannot resolve devdoc_dir for project '${project}' — set it in config.toml (or export DEVAGENT_TEST_DEVDOC)"
  [ -n "${devdoc}" ] \
    || die "devdoc_dir for project '${project}' resolved empty — check config.toml"
  printf '%s\n' "${devdoc}"
}
