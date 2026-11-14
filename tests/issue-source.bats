#!/usr/bin/env bats
# tests/issue-source.bats — scripts/lib/issue-source.sh (#1099).
# Every function is a non-fatal setter-global helper, called bare in the test
# shell (never inside $(...), register Issue-120/282). Legs expecting a nonzero
# rc use `fn args || rc=$?` — a bare nonzero call ends a bats body (Issue-589).

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/issue-source.sh"
}

teardown() { teardown_tmp_devagent_home; }

# _cfg <project-table-extra> <origin:0|1> <fork:0|1>
# The key line(s) go INSIDE [project.volk], never appended after a sub-table:
# an append after [...issue_source_fork] is the misplaced-key case.
_cfg() {
  local extra="$1" origin="$2" fork="$3"
  {
    printf '[project.volk]\nsource_dir = "/tmp/x"\ndevdoc_dir = "/tmp/y"\n'
    [[ -n "$extra" ]] && printf '%s\n' "$extra"
    if [[ "$origin" == 1 ]]; then
      printf '\n[project.volk.issue_source]\nbackend = "github"\nrepo = "gnuradio/volk"\ndir_prefix = "Issue-"\n'
    fi
    if [[ "$fork" == 1 ]]; then
      printf '\n[project.volk.issue_source_fork]\nbackend = "github"\nrepo = "mtibbits/volk"\ndir_prefix = "Issue-Fork-"\n'
    fi
  } > "$DA_HOME/config.toml"
}

@test "section: origin and fork map to their config tables" {
  run issue_source_section origin
  [ "$output" = "issue_source" ]
  run issue_source_section fork
  [ "$output" = "issue_source_fork" ]
}

@test "take_flag: no source flag leaves every arg in order" {
  issue_source_take_flag volk 42 --auto
  [ "$ISRC_FLAG" = "" ]
  [ "${#ISRC_REST[@]}" -eq 3 ]
  [ "${ISRC_REST[0]}" = "volk" ]
  [ "${ISRC_REST[1]}" = "42" ]
  [ "${ISRC_REST[2]}" = "--auto" ]
}

@test "take_flag: --fork is taken from any position" {
  issue_source_take_flag 42 --fork x
  [ "$ISRC_FLAG" = "fork" ]
  [ "${#ISRC_REST[@]}" -eq 2 ]
  [ "${ISRC_REST[0]}" = "42" ]
  [ "${ISRC_REST[1]}" = "x" ]
  issue_source_take_flag --origin 42
  [ "$ISRC_FLAG" = "origin" ]
  [ "${#ISRC_REST[@]}" -eq 1 ]
  [ "${ISRC_REST[0]}" = "42" ]
}

@test "take_flag: origin/fork positionals pass through" {
  issue_source_take_flag origin 42
  [ "$ISRC_FLAG" = "" ]
  [ "${#ISRC_REST[@]}" -eq 2 ]
  [ "${ISRC_REST[0]}" = "origin" ]
  [ "${ISRC_REST[1]}" = "42" ]
}

@test "take_flag: both flags fail rc 2 naming both" {
  local rc=0
  issue_source_take_flag --origin --fork || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ISRC_ERR" = "at most one of --origin, --fork may be given, got: '--origin' and '--fork'" ]
  [ "$ISRC_FLAG" = "" ]
}

@test "take_flag: a repeated flag fails rc 2" {
  local rc=0
  issue_source_take_flag --fork --fork || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ISRC_ERR" = "at most one of --origin, --fork may be given, got: '--fork' and '--fork'" ]
}

@test "take_flag: an =value spelling fails rc 2" {
  local rc=0
  issue_source_take_flag 42 --fork=x || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ISRC_ERR" = "--origin and --fork take no value, got: '--fork=x'" ]
  rc=0
  issue_source_take_flag 42 --origin= || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ISRC_ERR" = "--origin and --fork take no value, got: '--origin='" ]
}

@test "take_flag: a stale ISRC_ERR in the env does not change the outcome" {
  export ISRC_ERR="stale"
  issue_source_take_flag 42 --fork
  [ "$ISRC_ERR" = "" ]
  [ "$ISRC_FLAG" = "fork" ]
}

@test "configured: backend decides" {
  _cfg "" 1 0
  issue_source_configured volk origin
  local rc=0
  issue_source_configured volk fork || rc=$?
  [ "$rc" -eq 1 ]
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.issue_source_fork]
repo = "mtibbits/volk"
EOF
  rc=0
  issue_source_configured volk fork || rc=$?
  [ "$rc" -eq 1 ]
}

@test "default: the key wins (rule key)" {
  _cfg 'default_issue_source = "fork"' 1 1
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "fork" ]
  [ "$ISRC_RULE" = "key" ]
  [ "$ISRC_ERR" = "" ]
}

@test "default: one configured source wins (rule only)" {
  _cfg "" 0 1
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "fork" ]
  [ "$ISRC_RULE" = "only" ]
  _cfg "" 1 0
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "origin" ]
  [ "$ISRC_RULE" = "only" ]
}

@test "default: both sources and no key falls back to origin (rule fallback)" {
  _cfg "" 1 1
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "origin" ]
  [ "$ISRC_RULE" = "fallback" ]
  _cfg "" 0 0
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "origin" ]
  [ "$ISRC_RULE" = "fallback" ]
}

@test "default: a bad value is rc 1 naming the key" {
  local v rc
  for v in '"upstream"' '""' '1'; do
    _cfg "default_issue_source = $v" 1 1
    rc=0
    issue_source_default volk || rc=$?
    [ "$rc" -eq 1 ]
    [ "$ISRC_DEFAULT" = "" ]
    [ "$ISRC_RULE" = "" ]
    local shown="${v//\"/}"
    [ "$ISRC_ERR" = "[project.volk] default_issue_source must be \"origin\" or \"fork\", got: '$shown'" ]
  done
}

@test "default: a key naming an unconfigured source is rc 1" {
  local rc=0
  _cfg 'default_issue_source = "fork"' 1 0
  issue_source_default volk || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ISRC_DEFAULT" = "" ]
  [ "$ISRC_ERR" = '[project.volk] default_issue_source = "fork" but [project.volk.issue_source_fork] has no backend configured' ]
  rc=0
  _cfg 'default_issue_source = "origin"' 0 1
  issue_source_default volk || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ISRC_ERR" = '[project.volk] default_issue_source = "origin" but [project.volk.issue_source] has no backend configured' ]
}

@test "default: a table-valued key is rc 1 naming the key, never a fallback" {
  local rc=0
  _cfg 'default_issue_source = { v = "fork" }' 1 1
  issue_source_default volk 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
  [ "$ISRC_DEFAULT" = "" ]
  [ "$ISRC_RULE" = "" ]
  [ "$ISRC_ERR" = '[project.volk] default_issue_source must be "origin" or "fork", got a table' ]
}

@test "default: a key misplaced under [issue_source_fork] is not read" {
  _cfg "" 1 1
  # Appending lands the key in the fork sub-table — the misplaced shape.
  printf 'default_issue_source = "fork"\n' >> "$DA_HOME/config.toml"
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "origin" ]
  [ "$ISRC_RULE" = "fallback" ]
}

@test "default: an unreadable config is rc 2, never a fallback" {
  printf '[project.volk\nbroken = \n' > "$DA_HOME/config.toml"
  local rc=0
  issue_source_default volk || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ISRC_DEFAULT" = "" ]
  [[ "$ISRC_ERR" == *"could not read [project.volk] default_issue_source (config rc 2)"* ]]
}

@test "default: a CR-terminated value is read as its bare value" {
  printf '[project.volk]\r\ndefault_issue_source = "fork"\r\n\r\n[project.volk.issue_source]\r\nbackend = "github"\r\n\r\n[project.volk.issue_source_fork]\r\nbackend = "github"\r\n' > "$DA_HOME/config.toml"
  issue_source_default volk
  [ "$ISRC_DEFAULT" = "fork" ]
  [ "$ISRC_RULE" = "key" ]
}
