#!/usr/bin/env bash
# scripts/lib/paths.sh — path helpers. Safe to source multiple times.

plugin_root() {
  # The file lives at <root>/scripts/lib/paths.sh. Walk up two dirs.
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

devagent_home() {
  echo "${DA_HOME:-$HOME/.claude/devagent}"
}

config_path() {
  echo "$(devagent_home)/config.toml"
}

state_path() {
  local project="$1"
  [[ -n "$project" ]] || { echo "state_path: project required" >&2; return 1; }
  echo "$(devagent_home)/state/${project}.toml"
}

secrets_dir() {
  echo "$(devagent_home)/secrets"
}

expand_tilde() {
  local p="$1"
  echo "${p/#\~/$HOME}"
}
