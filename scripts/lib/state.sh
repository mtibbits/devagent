#!/usr/bin/env bash
# scripts/lib/state.sh — read/write ~/.claude/devagent/state/<project>.toml.
# Requires paths.sh and io.sh sourced first.

_state_toml() {
  python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"
}

_state_now() {
  date -Iseconds
}

state_init() {
  local project="$1" f
  [[ -n "$project" ]] || die "state_init: project required"
  f="$(state_path "$project")"
  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")" 2>/dev/null || true
  mkdir -p "$(secrets_dir)"
  chmod 700 "$(secrets_dir)" 2>/dev/null || true
  if [[ ! -f "$f" ]]; then
    install -m 600 /dev/null "$f"
    _state_toml set     "$f" active_issue   '""'
    _state_toml set     "$f" issue_dir      '""'
    _state_toml set     "$f" branch         '""'
    _state_toml set     "$f" baseline_sha   '""'
    _state_toml set     "$f" worktree_path  '""'
    _state_toml set-int "$f" last_step      0
    _state_toml set     "$f" last_step_name '""'
    _state_toml set     "$f" mr_url         '""'
    _state_toml set-int "$f" revision       1
    _state_toml set     "$f" updated_at     '""'
    chmod 600 "$f"
  fi
}

state_exists() {
  local project="$1"
  [[ -f "$(state_path "$project")" ]]
}

state_get() {
  local project="$1" key="$2"
  state_exists "$project" || return 1
  _state_toml get "$(state_path "$project")" "$key" 2>/dev/null
}

state_set() {
  local project="$1" key="$2" value="$3"
  state_init "$project"
  local f
  f="$(state_path "$project")"
  _state_toml set "$f" "$key" "$value"
  _state_toml set "$f" updated_at "$(_state_now)"
}

state_unset() {
  local project="$1" key="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "$key"
}

state_add_parked() {
  local project="$1" issue="$2"
  state_init "$project"
  _state_toml set-bool "$(state_path "$project")" "parked.${issue}" true
}

state_remove_parked() {
  local project="$1" issue="$2"
  state_exists "$project" || return 0
  _state_toml unset "$(state_path "$project")" "parked.${issue}"
}

state_list_parked() {
  local project="$1"
  state_exists "$project" || return 0
  _state_toml list-keys "$(state_path "$project")" parked 2>/dev/null || true
}

state_active_project() {
  local best="" best_ts=""
  local p ts ai
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ai="$(state_get "$p" active_issue 2>/dev/null || true)"
    [[ -z "$ai" ]] && continue
    ts="$(state_get "$p" updated_at 2>/dev/null || true)"
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best="$p"
      best_ts="$ts"
    fi
  done < <(_state_list_projects)
  [[ -n "$best" ]] || return 1
  echo "$best"
}

_state_list_projects() {
  local dir
  dir="$(devagent_home)/state"
  [[ -d "$dir" ]] || return 0
  ( cd "$dir" && for f in *.toml; do
      [[ -e "$f" ]] || continue
      echo "${f%.toml}"
    done )
}
