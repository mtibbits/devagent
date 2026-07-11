#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "state_init creates a mode-600 file" {
  state_init volk
  [ -f "$DA_HOME/state/volk.toml" ]
  assert_file_mode "$DA_HOME/state/volk.toml" 600
}

@test "state_exists reflects state_init" {
  run state_exists volk
  [ "$status" -ne 0 ]
  state_init volk
  run state_exists volk
  [ "$status" -eq 0 ]
}

@test "state_set then state_get round-trips" {
  state_init volk
  state_set volk active_issue Issue-676
  run state_get volk active_issue
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-676" ]
}

@test "state_unset removes a key" {
  state_init volk
  state_set volk active_issue Issue-676
  state_unset volk active_issue
  run state_get volk active_issue
  [ -z "$output" ]
}

@test "state_get on an unparseable state file errors loudly, not silently absent (#99)" {
  state_init volk
  # Corrupt the state file so tomllib can't parse it.
  printf 'this is = not = valid toml\n' > "$DA_HOME/state/volk.toml"
  run state_get volk active_issue
  [ "$status" -eq 2 ]                          # distinct from key-absent
  [[ "$output" == *"unparseable"* ]] || [[ "$output" == *"repair"* ]]
}

@test "state_set warns when active_issue changes between two issues" {
  state_init volk
  state_set volk active_issue Issue-61
  run state_set volk active_issue Issue-55
  [ "$status" -eq 0 ]
  [[ "$output" == *"active_issue is changing from 'Issue-61' to 'Issue-55'"* ]]
}

@test "state_set does NOT warn on first set (empty to issue)" {
  state_init volk
  run state_set volk active_issue Issue-61
  [ "$status" -eq 0 ]
  [[ "$output" != *"active_issue is changing"* ]]
}

@test "state_set does NOT warn when clearing active_issue (issue to empty)" {
  state_init volk
  state_set volk active_issue Issue-61
  run state_set volk active_issue ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"active_issue is changing"* ]]
}

@test "state_set does NOT warn when setting same issue (no change)" {
  state_init volk
  state_set volk active_issue Issue-61
  run state_set volk active_issue Issue-61
  [ "$status" -eq 0 ]
  [[ "$output" != *"active_issue is changing"* ]]
}

@test "parked list add/remove/list is idempotent" {
  state_init volk
  state_add_parked volk Issue-12
  state_add_parked volk Issue-12   # idempotent
  state_add_parked volk Issue-34
  run state_list_parked volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
  state_remove_parked volk Issue-12
  state_remove_parked volk Issue-12 # idempotent
  run state_list_parked volk
  [[ "$output" != *"Issue-12"* ]]
  [[ "$output" == *"Issue-34"* ]]
}

# (#330: state_active_project deleted — dead, zero production callers.)

@test "_state_list_projects filters _* and dotted sidecar files (#83)" {
  state_init devagent
  state_init volk
  : > "$DA_HOME/state/_active.toml"          # global pointer (phantom 'project')
  : > "$DA_HOME/state/volk.depends.toml"     # deps sidecar  (phantom 'project')
  : > "$DA_HOME/state/devagent.toml.lock"    # lock sidecar  (not a *.toml match)
  run _state_list_projects
  [ "$status" -eq 0 ]
  [[ "$output" == *devagent* ]]
  [[ "$output" == *volk* ]]
  [[ "$output" != *_active* ]]               # filtered
  [[ "$output" != *volk.depends* ]]          # filtered
}

@test "state_set updates updated_at field automatically" {
  state_init volk
  state_set volk active_issue Issue-1
  run state_get volk updated_at
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "state_set round-trips a value containing embedded quotes" {
  state_init volk
  local original='say "hi" then go'
  state_set volk weirdkey "$original"
  run state_get volk weirdkey
  [ "$status" -eq 0 ]
  [ "$output" = "$original" ]
}

@test "state_init creates secrets dir at mode 700" {
  # Remove the helper-created secrets dir to verify state_init creates it.
  rmdir "$DA_HOME/secrets" 2>/dev/null || true
  state_init volk
  [ -d "$DA_HOME/secrets" ]
  assert_file_mode "$DA_HOME/secrets" 700
}

@test "state_context_save snapshots per-issue keys into [context.<issue>] (#98)" {
  state_set volk branch "fix/676-foo"
  state_set volk mr_url "https://example.com/pr/1"
  state_context_save volk Issue-676
  f="$(state_path volk)"
  [ "$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-676.branch)" = "fix/676-foo" ]
  [ "$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-676.mr_url)" = "https://example.com/pr/1" ]
}

@test "state_context_clear resets per-issue keys to defaults (#98)" {
  state_set volk branch "fix/676-foo"
  state_set volk pending_comments_file "/tmp/c.md"
  state_context_clear volk
  [ -z "$(state_get volk branch)" ]
  run state_get volk pending_comments_file
  [ -z "$output" ]
  f="$(state_path volk)"
  grep -qE '^revision = 1$' "$f"
  grep -qE '^last_step = 0$' "$f"
}

@test "state_context_restore restores keys, deletes snapshot, ints unquoted (#98)" {
  state_set volk branch "fix/676-foo"
  state_set_int volk revision 3
  state_context_save volk Issue-676
  state_context_clear volk
  state_set volk branch "fix/999-other"   # simulate another issue's residue
  state_context_restore volk Issue-676
  [ "$(state_get volk branch)" = "fix/676-foo" ]
  f="$(state_path volk)"
  grep -qE '^revision = 3$' "$f"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" list-keys "$f" context.Issue-676
  [ "$status" -ne 0 ]
}

@test "state_context_restore without snapshot clears keys and warns (#98)" {
  state_set volk branch "fix/999-other"
  run state_context_restore volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" == *"no saved context"* ]]
  f="$(state_path volk)"
  grep -qE '^branch = ""$' "$f"
}

@test "state_context_save replaces a stale snapshot instead of merging (#98 review M1)" {
  state_set volk branch "fix/676-foo"
  state_set volk mr_url "https://example.com/pr/OLD"
  state_context_save volk Issue-676
  state_context_clear volk
  state_set volk branch "fix/676-v2"   # re-branched; no MR yet
  state_context_save volk Issue-676
  f="$(state_path volk)"
  [ "$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-676.branch)" = "fix/676-v2" ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-676.mr_url
  [ "$status" -ne 0 ]   # stale mr_url must NOT survive the re-save
}

# --- #96: state_set_many / race-free warn (#330: state_set_if deleted, dead) ---

@test "state_set_many writes typed keys + one updated_at in one transaction (#96)" {
  state_init volk
  state_set_many volk str branch "feat/9-x" str baseline_sha "abc123" int revision 2
  [ "$(state_get volk branch)" = "feat/9-x" ]
  [ "$(state_get volk baseline_sha)" = "abc123" ]
  grep -qE '^revision = 2$' "$(state_path volk)"
  grep -cE '^updated_at = ' "$(state_path volk)" | grep -qx 1
}

@test "state_set_many warns on active_issue clobber, silent on clear/first-set (#96)" {
  state_init volk
  run state_set_many volk str active_issue "Issue-1" str issue_dir "/tmp/i1"
  [[ "$output" != *"active_issue is changing"* ]]
  state_set_many volk str active_issue "Issue-1" str issue_dir "/tmp/i1"
  run state_set_many volk str active_issue "Issue-2" str issue_dir "/tmp/i2"
  [[ "$output" == *"active_issue is changing from 'Issue-1' to 'Issue-2'"* ]]
  run state_set_many volk str active_issue "" str issue_dir ""
  [[ "$output" != *"active_issue is changing"* ]]
}

# --- #330: state API hygiene — one-transaction folding + updated_at on unset ---

@test "state_unset bumps updated_at (#330)" {
  state_init volk
  state_set volk active_issue Issue-1
  # Force a known-old timestamp; the old state_unset never touched updated_at.
  _state_toml set "$(state_path volk)" updated_at "2000-01-01T00:00:00+00:00"
  state_unset volk active_issue
  [ -z "$(state_get volk active_issue)" ]
  [ "$(state_get volk updated_at)" != "2000-01-01T00:00:00+00:00" ]
}

@test "state_unset is ONE _toml transaction (#330)" {
  state_init volk
  state_set volk active_issue Issue-1
  local _TOML_CALLS=0
  _state_toml() { _TOML_CALLS=$((_TOML_CALLS + 1)); python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"; }
  state_unset volk active_issue
  [ "$_TOML_CALLS" -eq 1 ]
}

@test "state_set_int folds updated_at into ONE _toml transaction (#330)" {
  state_init volk
  local _TOML_CALLS=0
  _state_toml() { _TOML_CALLS=$((_TOML_CALLS + 1)); python3 "$(plugin_root)/scripts/lib/_toml.py" "$@"; }
  state_set_int volk revision 4
  [ "$_TOML_CALLS" -eq 1 ]
  grep -qE '^revision = 4$' "$(state_path volk)"
  grep -cE '^updated_at = ' "$(state_path volk)" | grep -qx 1
}

@test "state_set clobber-warn reads old value in-lock via --print-old (#96)" {
  state_init volk
  state_set volk active_issue "Issue-1"
  run state_set volk active_issue "Issue-2"
  [[ "$output" == *"active_issue is changing from 'Issue-1' to 'Issue-2'"* ]]
  # stdout leak check: the old value must NOT appear alone on stdout
  [[ "$output" != "Issue-1" ]]
}

# ---- #240: issue-keyed state API (table authoritative + conditional mirror) --

@test "state_issue_set_many mirrors top-level when issue IS active (#240)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_issue_set_many volk Issue-1 str branch "feat/a" int last_step 7
  [ "$(state_get volk context.Issue-1.branch)" = "feat/a" ]
  [ "$(state_get volk branch)" = "feat/a" ]
  [ "$(state_get volk last_step)" = "7" ]
}

@test "state_issue_set_many writes table ONLY when issue is not active (#240 AC2)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk branch "feat/a"
  state_issue_set_many volk Issue-2 str branch "feat/b" int last_step 3
  [ "$(state_get volk context.Issue-2.branch)" = "feat/b" ]
  # The other session's shared view is untouched.
  [ "$(state_get volk branch)" = "feat/a" ]
  [ "$(state_get volk active_issue)" = "Issue-1" ]
}

@test "state_issue_get: table hit wins over top-level (#240)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk branch "top-level-stale"
  state_issue_set_many volk Issue-1 str branch "table-fresh"
  [ "$(state_issue_get volk Issue-1 branch)" = "table-fresh" ]
}

@test "state_issue_get: miss + active issue falls back to top-level (migration) (#240 AC5)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk branch "pre-existing"
  [ "$(state_issue_get volk Issue-1 branch)" = "pre-existing" ]
}

@test "state_issue_get: miss + NON-active issue returns the per-key default (#240)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk branch "not-yours"
  [ -z "$(state_issue_get volk Issue-2 branch)" ]
  [ "$(state_issue_get volk Issue-2 revision)" = "1" ]
  [ "$(state_issue_get volk Issue-2 last_step)" = "0" ]
}

@test "state_issue_set_many is ONE transaction (single updated_at bump) (#240)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_issue_set_many volk Issue-1 str branch "x" str baseline_sha "y" int revision 2
  # No torn intermediate observable: all three landed.
  [ "$(state_get volk branch)" = "x" ]
  [ "$(state_get volk baseline_sha)" = "y" ]
  [ "$(state_get volk revision)" = "2" ]
}

@test "state_issue_set_many rejects an invalid issue id defensively (#240)" {
  state_init volk
  run state_issue_set_many volk 'Issue 2]' str branch "x"
  [ "$status" -ne 0 ]
  run state_get volk active_issue
  [ "$status" -eq 0 ]
}

@test "mixed-generation read: adopted key from table, unadopted from top-level (#240 A3)" {
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk branch "old-branch"
  state_set volk mr_url "old-url"
  state_issue_set_many volk Issue-1 str branch "new-branch"
  [ "$(state_issue_get volk Issue-1 branch)" = "new-branch" ]
  [ "$(state_issue_get volk Issue-1 mr_url)" = "old-url" ]
}

@test "issue_dir_for derivation byte-matches pull.sh's stored computation (#240)" {
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  cat > "$DA_HOME/config.toml" <<CFG
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/src"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/volk/"
CFG
  devdoc="$(config_get_project_field volk devdoc_dir)"
  expected="${devdoc%/}/Issue-9"
  [ "$(issue_dir_for volk Issue-9)" = "$expected" ]
}

@test "STATE_ISSUE_KEYS and _STATE_RESTORE_SPECS enumerate the same key set (#419)" {
  # Drift is a cross-issue value LEAK: a key snapshotted (STATE_ISSUE_KEYS) but not
  # reset/restored (_STATE_RESTORE_SPECS) carries a stale value across context
  # switches. lib/state.sh's own comment documents the hazard; this makes it CI.
  local keys specs i
  keys="$(printf '%s\n' $STATE_ISSUE_KEYS | LC_ALL=C sort)"
  local -a spec_keys=()
  for ((i=1; i<${#_STATE_RESTORE_SPECS[@]}; i+=3)); do spec_keys+=("${_STATE_RESTORE_SPECS[i]}"); done
  specs="$(printf '%s\n' "${spec_keys[@]}" | LC_ALL=C sort)"
  [ "$keys" = "$specs" ]
}
