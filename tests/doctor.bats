#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Real dirs the doctor must find.
  mkdir -p "$DA_HOME/fake-src" "$DA_HOME/fake-devdoc"
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
default_baseline = "origin/main"

[project.volk.issue_source]
backend    = "github"
repo       = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend  = "github"
upstream = "gnuradio/volk"
fork     = "mtibbits/volk"
TOML
  # Have the state file + secrets dir bootstrapped.
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
  state_init volk
  secrets_bootstrap
}
teardown() { teardown_tmp_devagent_home; }

@test "doctor passes on a well-formed setup" {
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "doctor flags a missing source_dir" {
  rmdir "$DA_HOME/fake-src"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"source_dir"* ]]
}

@test "doctor flags a missing devdoc_dir" {
  rmdir "$DA_HOME/fake-devdoc"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"devdoc_dir"* ]]
}

@test "doctor flags missing required field" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/config.toml" project.volk.issue_source.repo
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue_source.repo"* ]]
}

@test "doctor flags missing state file" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"state"* ]]
}

@test "doctor flags drifted secrets dir mode" {
  chmod 755 "$DA_HOME/secrets"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets"* ]]
}

@test "doctor flags unknown checklist_template" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" defaults.checklist_template '"no-such"'
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"template"* ]]
}

@test "doctor without project arg runs against all projects" {
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
}

@test "doctor fails when config does not exist" {
  rm "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}

_seed_316_active_issue() {   # $1 = branch-step glyph (x = corrupt, ' ' = fresh)
  mkdir -p "$DA_HOME/fake-devdoc/Issue-1"
  cat > "$DA_HOME/fake-devdoc/Issue-1/checklist.md" <<CL
## Revision 1

- [x]  0. pull
- [$1]  6. branch
- [ ] 10. commit
CL
  state_set volk active_issue Issue-1
  state_set volk issue_dir "$DA_HOME/fake-devdoc/Issue-1"
  # branch key left absent => empty (the resume-after-cleanup state)
}

@test "doctor flags an active issue whose branch step is done but has no branch (#316)" {
  _seed_316_active_issue x
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"316"* ]]
}

@test "doctor does NOT flag a fresh active issue (branch step pending, empty branch) (#316)" {
  _seed_316_active_issue ' '
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"316"* ]]
}
