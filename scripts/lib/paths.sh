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
  # ~ / ~/...  → $HOME (env var). ~user / ~user/... → that user's passwd home
  # (#82: the old `${p/#\~/$HOME}` mis-expanded ~user to ${HOME}user). An unknown
  # user (or no getent) leaves the value untouched rather than mangling it.
  # Anything not starting with a leading ~ is returned verbatim.
  local p="$1"
  # SC2088: the quoted ~ here is a case PATTERN matching a literal leading tilde
  # in the input — intentionally not an expansion.
  # shellcheck disable=SC2088
  case "$p" in
    "~"|"~/"*)
      printf '%s\n' "${p/#\~/$HOME}" ;;
    "~"*)
      local rest user home
      rest="${p#\~}"            # user[/...]
      user="${rest%%/*}"        # user
      home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
      if [ -n "$home" ]; then
        printf '%s\n' "${home}${rest#"$user"}"
      else
        printf '%s\n' "$p"
      fi ;;
    *)
      printf '%s\n' "$p" ;;
  esac
}
