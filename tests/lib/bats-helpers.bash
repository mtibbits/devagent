# tests/lib/bats-helpers.bash
# Sourced by every .bats test via `load 'lib/bats-helpers'`.

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export PLUGIN_ROOT

setup_tmp_devagent_home() {
  DA_HOME="$(mktemp -d)"
  export DA_HOME
  mkdir -p "$DA_HOME/state" "$DA_HOME/secrets"
  chmod 700 "$DA_HOME/secrets"
}

teardown_tmp_devagent_home() {
  if [[ -n "${DA_HOME:-}" && -d "$DA_HOME" && "$DA_HOME" == /tmp/* ]]; then
    rm -rf "$DA_HOME"
  fi
}

fixtures_dir() {
  echo "$PLUGIN_ROOT/tests/fixtures"
}

assert_file_mode() {
  local path="$1" want="$2"
  local got
  got="$(stat -c '%a' "$path")"
  [[ "$got" == "$want" ]] || {
    echo "expected mode $want on $path, got $got" >&2
    return 1
  }
}

install_fixture_config() {
  local fixture="$1"
  cp "$(fixtures_dir)/$fixture" "$DA_HOME/config.toml"
}
