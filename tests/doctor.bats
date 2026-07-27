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
- [$1]  8. branch
- [ ] 12. commit
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

_seed_329_active_issue() {   # $1 = commit-step glyph (' ' = divergent, x = coherent)
  mkdir -p "$DA_HOME/fake-devdoc/Issue-1"
  cat > "$DA_HOME/fake-devdoc/Issue-1/checklist.md" <<CL
## Revision 1

- [x]  0. pull
- [x]  8. branch
- [$1] 12. commit
CL
  state_set volk active_issue Issue-1
  state_set volk issue_dir "$DA_HOME/fake-devdoc/Issue-1"
  state_set volk branch "fix/1-real"      # so the #316 coherence check passes
  state_set volk last_step_name "commit"  # state claims commit is the last step
}

@test "doctor flags last_step vs checklist divergence (#329)" {
  _seed_329_active_issue ' '   # state says commit done; checklist commit unmarked
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"step coherence"*"last_step_name=commit"* ]]
}

@test "doctor does NOT flag when last_step matches the checklist (#329)" {
  _seed_329_active_issue x     # commit step [x] agrees with state
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step coherence (Issue-1)"*"OK"* ]] || [[ "$output" == *"OK"*"step coherence"* ]]
}

@test "doctor does NOT flag a HEALTHY branched issue (recorded branch + branch step done) (#316 regression)" {
  # The false-positive axis the first cut missed: a normal in-progress issue has
  # a NON-EMPTY recorded branch AND branch step [x]. The #316 check must pass it.
  # (Catches doctor calling state_ctx_get without sourcing active.sh — that made
  # the branch read empty always and flagged every healthy issue.)
  _seed_316_active_issue x
  state_set volk branch "fix/1-real"
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"316"* ]]
  [[ "$output" == *"state coherence"*"OK"* ]] || [[ "$output" == *"OK"*"state coherence"* ]] || [[ "$output" == *"coherence (Issue-1) OK"* ]]
}

@test "doctor reports the git-reflex guard state, never failing on off then ON (#352)" {
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [[ "$output" == *"git-reflex guard"* ]]
  [[ "$output" == *"off"* ]]
  # Enabling it in [defaults] flips the report to ON — still not a failure.
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set-bool "$DA_HOME/config.toml" defaults.git_guard true
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [[ "$output" == *"git-reflex guard"* ]]
  [[ "$output" == *"ON"* ]]
}

@test "doctor reports OFF and FAILs when git_guard=true has a trailing comment the hook rejects (#432)" {
  # A valid-TOML `git_guard = true  # note`: tomllib parses it as true, but the
  # hook's awk gate requires a LITERALLY BARE line — so the hook stays off while a
  # naive tomllib-only doctor would report ON. doctor must side with the hook.
  # (Insert via awk, not `sed -i` — that would trip the #429 state-TOML canary.)
  awk '/^\[defaults\]/{print; print "git_guard = true  # note"; next} {print}' \
    "$DA_HOME/config.toml" > "$DA_HOME/config.toml.tmp" && mv "$DA_HOME/config.toml.tmp" "$DA_HOME/config.toml"

  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [[ "$output" == *"git-reflex guard"* ]]
  [[ "$output" == *"OFF despite git_guard=true"* ]]        # divergence surfaced
  [[ "$output" == *"FAIL"*"git-reflex guard"* ]] || [[ "$output" == *"FAIL git-reflex guard: OFF despite"* ]]
  # never reports ON for a hook that will not fire
  [[ "$output" != *"git-reflex guard: ON"* ]]
}

@test "doctor reports ON when git_guard=true is a literally bare line (#432 agreement)" {
  # set-bool writes the canonical bare `git_guard = true` — the hook's gate accepts
  # it, so doctor and the hook AGREE on ON.
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set-bool "$DA_HOME/config.toml" defaults.git_guard true
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [[ "$output" == *"git-reflex guard: ON"* ]]
  [[ "$output" != *"OFF despite"* ]]
}

@test "doctor's git_guard awk gate is byte-identical to the hook's (drift canary, #432/#433)" {
  # doctor replicates the hook's per-project awk gate (#433); if either drifts, the
  # ON/off divergence class #432 fixed silently reopens. Extract the WHOLE gate block
  # (from `awk -v proj=` through the `END { exit((ps …` line — incl. the `/^\[/`
  # section trigger that makes subtable scoping work) and compare it trimmed, so ANY
  # change to one file's gate — value rules OR section handling — fails.
  # Capture the awk PROGRAM BODY only (from the line AFTER `awk -v proj=` — the
  # invocation line differs by shell var name — through the `END { exit((ps …` line).
  _extract_gate() {
    awk '/awk -v proj=/{f=1; next} f{print} /END \{ exit\(\(ps/{exit}' "$1" | sed 's/^[[:space:]]*//'
  }
  local hook_gate doctor_gate
  hook_gate="$(_extract_gate "$PLUGIN_ROOT/hooks/git-guard.sh")"
  doctor_gate="$(_extract_gate "$PLUGIN_ROOT/scripts/doctor.sh")"
  [ -n "$hook_gate" ]
  [[ "$hook_gate" == *'/^\['* ]]                 # the section-trigger line is captured
  [ "$hook_gate" = "$doctor_gate" ] || { echo "gate DRIFT:"; diff <(echo "$hook_gate") <(echo "$doctor_gate"); false; }
}
