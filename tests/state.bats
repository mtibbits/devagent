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

@test "state_active_project returns the most recently updated" {
  state_init volk
  state_init toy
  state_set toy  active_issue Issue-1
  sleep 1
  state_set volk active_issue Issue-2
  run state_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}

@test "state_active_project ignores projects with null active_issue" {
  state_init toy
  run state_active_project
  [ "$status" -ne 0 ]
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
