#!/usr/bin/env bats
# #459: plugin.json userConfig SEEDS the /devagent:init interview at plugin-enable
# time (CLAUDE_PLUGIN_OPTION_<KEY> env vars), but config.toml is the single source of
# truth (it WINS). Verified on the installed claude 2.1.75 (userConfig validates;
# `${CLAUDE_PLUGIN_DATA}` exists) — see the issue's actualWork for the empirical checks.

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$DA_HOME/bin"; mkdir -p "$STUB_BIN"
  printf '#!/usr/bin/env bash\necho main\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  unset CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT
}
teardown() { teardown_tmp_devagent_home; }

_init() {  # run init.sh with the required non-devdoc answers via env; extra env from caller
  DA_INIT_SOURCE_DIR="/tmp/src" DA_INIT_ISSUE_BACKEND=github \
  DA_INIT_ISSUE_REPO="org/repo" DA_INIT_CODE_FORK="me/repo" \
  run bash "$REPO/scripts/init.sh" "$@"
}

@test "plugin.json userConfig block validates in shape (devdoc_root + default_project, each with a title) (#459)" {
  run python3 - "$REPO/.claude-plugin/plugin.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
uc = d.get("userConfig")
assert isinstance(uc, dict), "no userConfig"
for k in ("devdoc_root", "default_project"):
    assert k in uc, f"missing userConfig.{k}"
    assert uc[k].get("title"), f"userConfig.{k}.title required (claude 2.1.75 validator)"
    assert uc[k].get("type"), f"userConfig.{k}.type required"
print("userConfig shape OK")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "SEED: CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT becomes the devdoc_dir when no explicit answer (#459)" {
  CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT="/seeded/dd" _init seedproj    # no DA_INIT_DEVDOC_DIR
  [ "$status" -eq 0 ]
  grep -qE '^\s*devdoc_dir\s*=\s*"/seeded/dd"' "$DA_HOME/config.toml"
}

@test "config.toml WINS: an explicit answer beats the userConfig seed (#459)" {
  DA_INIT_DEVDOC_DIR="/explicit/dd" CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT="/seeded/dd" _init winproj
  [ "$status" -eq 0 ]
  grep -qE '^\s*devdoc_dir\s*=\s*"/explicit/dd"' "$DA_HOME/config.toml"
}

@test "config.toml WINS: re-init of an existing project DIES (single source of truth) (#459)" {
  DA_INIT_DEVDOC_DIR="/dd" _init dupproj
  [ "$status" -eq 0 ]
  DA_INIT_DEVDOC_DIR="/other" CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT="/seeded" _init dupproj   # exists → dies
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "SEED: no arg + CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT → that project is bootstrapped (#459)" {
  DA_INIT_DEVDOC_DIR="/dd" CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT="fallbackproj" _init   # no positional arg
  [ "$status" -eq 0 ]
  grep -qE '^\[project\.fallbackproj\]' "$DA_HOME/config.toml"
}

@test "no arg + no userConfig default_project → usage (unchanged) (#459)" {
  DA_INIT_DEVDOC_DIR="/dd" _init            # no arg, no CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "SEED is validated: a malformed default_project still dies on the project-name regex (#459)" {
  DA_INIT_DEVDOC_DIR="/dd" CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT="bad/name" _init   # slash → invalid
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad project name"* ]]
}

@test "an explicit project arg beats the default_project seed (#459)" {
  DA_INIT_DEVDOC_DIR="/dd" CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT="envproj" _init argwins
  [ "$status" -eq 0 ]
  grep -qE '^\[project\.argwins\]' "$DA_HOME/config.toml"
  run grep -qE '^\[project\.envproj\]' "$DA_HOME/config.toml"
  [ "$status" -ne 0 ]   # the env seed did NOT create a project
}
