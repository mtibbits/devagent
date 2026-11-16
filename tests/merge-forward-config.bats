#!/usr/bin/env bats
# #1125: [project.<name>.merge_forward] — the config reader, the shared predicates
# (driver, list membership, merge gate) and doctor's check_merge_forward.

load 'lib/bats-helpers'
load 'lib/doctor-harness'

setup() {
  setup_tmp_devagent_home
  seed_doctor_project
  stub_claude_cli enabled
}
teardown() { teardown_tmp_devagent_home; }

# _mf_table <toml-lines...>: append a [project.volk.merge_forward] table.
_mf_table() {
  { printf '\n[project.volk.merge_forward]\n'; printf '%s\n' "$@"; } >> "$DA_HOME/config.toml"
}

# _mf_lines: doctor's output lines that mention merge_forward.
_mf_lines() { printf '%s\n' "$output" | grep -c 'merge_forward' || true; }

# _git_src: make fake-src a git repo tracking CHANGELOG.md.
_git_src() {
  git -C "$DA_HOME/fake-src" init -q
  printf '# Changelog\n' > "$DA_HOME/fake-src/CHANGELOG.md"
  git -C "$DA_HOME/fake-src" add CHANGELOG.md
  git -C "$DA_HOME/fake-src" -c user.name=t -c user.email=t@t commit -q -m init
}

@test "#1125 doctor: append_only as a string is FAIL naming the key" {
  _mf_table 'verify = "ci"' 'append_only = "CHANGELOG.md"'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.merge_forward — merge_forward.append_only must be an array of strings"* ]]
  [[ "$output" == *"fix [project.volk.merge_forward] append_only"* ]]
}

@test "#1125 doctor: an absolute append_only entry is FAIL" {
  _mf_table 'verify = "ci"' 'append_only = ["/etc/CHANGELOG.md"]'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.merge_forward — merge_forward.append_only entry '/etc/CHANGELOG.md' is not an exact repo-relative file path"* ]]
  [[ "$output" == *"fix [project.volk.merge_forward] append_only"* ]]
}

@test "#1125 doctor: a .. append_only entry is FAIL" {
  _mf_table 'verify = "ci"' 'append_only = ["docs/../CHANGELOG.md"]'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry 'docs/../CHANGELOG.md' is not an exact repo-relative file path"* ]]
  [[ "$output" == *"fix [project.volk.merge_forward] append_only"* ]]
}

@test "#1125 doctor: a glob append_only entry is FAIL" {
  _mf_table 'verify = "ci"' 'append_only = ["CHANGES*.md"]'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry 'CHANGES*.md' is not an exact repo-relative file path"* ]]
  [[ "$output" == *"fix [project.volk.merge_forward] append_only"* ]]
}

@test "#1125 doctor: verify = \"always\" is FAIL naming the key" {
  _mf_table 'verify = "always"'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.merge_forward — merge_forward.verify must be \"ci\" or \"preship\" (got 'always'); fix [project.volk.merge_forward] verify"* ]]
}

@test "#1125 doctor: an entry naming no tracked file warns" {
  _git_src
  _mf_table 'verify = "ci"' 'append_only = ["NEWS.md"]'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN project.volk.merge_forward.append_only — 'NEWS.md' names no tracked file in $DA_HOME/fake-src"* ]]
}

@test "#1125 doctor: a tracked append_only entry does not warn (control)" {
  _git_src
  _mf_table 'verify = "ci"' 'append_only = ["CHANGELOG.md"]'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"merge_forward.append_only"* ]]
}

@test "#1125 doctor: verify = \"ci\" with merge_checks = \"if-present\" warns" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.merge_checks if-present
  _mf_table 'verify = "ci"'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *'WARN project.volk.merge_forward.verify — verify = "ci" with merge_checks = "if-present": a project without CI can never merge a forwarded head (rule 17)'* ]]
}

@test "#1125 doctor: verify = \"ci\" with merge_checks = \"required\" does not warn (control)" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.merge_checks required
  _mf_table 'verify = "ci"'
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"merge_forward.verify"* ]]
}

@test "#1125 doctor: no merge_forward table prints no merge_forward line" {
  run "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_mf_lines)" -eq 0 ]
}

# The predicates, sourced as their callers source them.
_mf_lib() {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/merge-forward.sh"
}

@test "#1125 merge_forward_driver: union refuses; unspecified, set, unset, text, binary pass" {
  _mf_lib
  merge_forward_driver union
  merge_forward_driver ours
  run merge_forward_driver unspecified; [ "$status" -eq 1 ]
  run merge_forward_driver set; [ "$status" -eq 1 ]
  run merge_forward_driver unset; [ "$status" -eq 1 ]
  run merge_forward_driver text; [ "$status" -eq 1 ]
  run merge_forward_driver binary; [ "$status" -eq 1 ]
}

@test "#1125 merge gate predicate: real-corpus must-trip and must-not-trip" {
  _mf_lib
  local d="$DA_HOME/gate" f rc
  for f in 995 1009 887; do
    mkdir -p "$d/$f"; cp "$PLUGIN_ROOT/tests/fixtures/merge-gate/$f.md" "$d/$f/mr.md"
  done
  rc=0; merge_forward_gate "$d/995" || rc=$?;  [ "$rc" -eq 0 ]; [[ "$MF_GATE_LINE" == 1 ]]
  rc=0; merge_forward_gate "$d/1009" || rc=$?; [ "$rc" -eq 0 ]
  rc=0; merge_forward_gate "$d/887" || rc=$?;  [ "$rc" -eq 1 ]
  mkdir -p "$d/none"
  rc=0; merge_forward_gate "$d/none" || rc=$?; [ "$rc" -eq 2 ]
}

@test "#1125 merge_forward_listed: byte-equal membership only" {
  _mf_lib
  _mf_table 'verify = "ci"' 'append_only = ["CHANGELOG.md", "docs/NEWS.md"]'
  merge_forward_resolve volk
  [ "$MF_VERIFY" = ci ]
  merge_forward_listed CHANGELOG.md
  merge_forward_listed docs/NEWS.md
  run merge_forward_listed changelog.md; [ "$status" -eq 1 ]
  run merge_forward_listed ./CHANGELOG.md; [ "$status" -eq 1 ]
}

@test "#1125 merge_forward_resolve: an absent table gives preship and no list" {
  _mf_lib
  merge_forward_resolve volk
  [ "$MF_VERIFY" = preship ]
  [ "${#MF_APPEND_ONLY[@]}" -eq 0 ]
}
