# tests/lib/bats-helpers.bash
# Sourced by every .bats test via `load 'lib/bats-helpers'`.

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export PLUGIN_ROOT
# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"

setup_tmp_devagent_home() {
  DA_HOME="$(mktemp -d)"
  export DA_HOME
  mkdir -p "$DA_HOME/state" "$DA_HOME/secrets"
  chmod 700 "$DA_HOME/secrets"
}

teardown_tmp_devagent_home() {
  # #106 (F10): mktemp -d honors $TMPDIR, so on macOS / sandboxed TMPDIR the temp
  # home is not under /tmp and would leak. Accept ${TMPDIR:-/tmp} too (normalized).
  local tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}"
  if [[ -n "${DA_HOME:-}" && -d "$DA_HOME" \
        && ( "$DA_HOME" == /tmp/* || "$DA_HOME" == "$tmp"/* ) ]]; then
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

# skill_frontmatter <file> — echo a markdown file's YAML frontmatter (the block
# between the leading `---` markers). The extractor idiom was independently
# copied into tests/lib/skill-fixture-check.sh and tests/skill-next-size-canary.bats
# before this existed; new callers should use this.
skill_frontmatter() {
    awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$1"
}
