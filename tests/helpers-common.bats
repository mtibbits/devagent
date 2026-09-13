#!/usr/bin/env bats
# #335: unit tests for the shared fixture set/mark helpers in helpers/common.bash
load 'helpers/common'

setup()    { devagent_test_setup; }
teardown() { devagent_test_teardown; }

STATE() { echo "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"; }
CFG()   { echo "$HOME/.claude/devagent/config.toml"; }
TOML()  { echo "${BATS_TEST_DIRNAME%/tests}/scripts/lib/_toml.py"; }
CL()    { echo "$DEVDOC_DIR/Issue-1/checklist.md"; }

# --- Task 1: .toml set/unset helpers ----------------------------------------

@test "devagent_state_set writes a string scalar readable via _toml.py get" {
  devagent_state_set "$(STATE)" branch "fix/1-x"
  run python3 "$(TOML)" get "$(STATE)" branch
  [ "$status" -eq 0 ]
  [ "$output" = "fix/1-x" ]
}

@test "devagent_state_set round-trips the empty string" {
  devagent_state_set "$(STATE)" baseline_sha ""
  run python3 "$(TOML)" get "$(STATE)" baseline_sha
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "devagent_config_set_bool addresses a nested key" {
  devagent_config_set_bool "$(CFG)" "project.$TEST_PROJECT.permissions.push_mr" false
  run python3 "$(TOML)" get "$(CFG)" "project.$TEST_PROJECT.permissions.push_mr"
  [ "$output" = "false" ]
}

@test "devagent_config_set_bool adds an absent nested key" {
  devagent_config_set_bool "$(CFG)" "project.$TEST_PROJECT.permissions.merge_mr" true
  run python3 "$(TOML)" get "$(CFG)" "project.$TEST_PROJECT.permissions.merge_mr"
  [ "$output" = "true" ]
}

@test "devagent_config_set_int addresses a nested key" {
  # The bare-integer twin of set_bool above (#593). `_set_suite_jobs` in
  # run-suite.bats greps for `suite_jobs = 4` UNQUOTED, so the shape is the
  # contract, not just the value: assert the TOML text as well as the read-back.
  devagent_config_set_int "$(CFG)" "project.$TEST_PROJECT.suite_jobs" 4
  run python3 "$(TOML)" get "$(CFG)" "project.$TEST_PROJECT.suite_jobs"
  [ "$output" = "4" ]
  grep -q "^suite_jobs = 4\$" "$(CFG)"                 # bare, not "4"
}

@test "devagent_config_set_int adds an absent nested key" {
  devagent_config_set_int "$(CFG)" "project.$TEST_PROJECT.analyze_timeout" 1800
  run python3 "$(TOML)" get "$(CFG)" "project.$TEST_PROJECT.analyze_timeout"
  [ "$output" = "1800" ]
  grep -q "^analyze_timeout = 1800\$" "$(CFG)"
}

@test "devagent_config_unset removes a key" {
  devagent_config_unset "$(CFG)" "project.$TEST_PROJECT.permissions.cleanup_on_merge"
  run python3 "$(TOML)" get "$(CFG)" "project.$TEST_PROJECT.permissions.cleanup_on_merge"
  [ "$status" -ne 0 ]
}

@test "devagent_state_set FAILS LOUD on a nonexistent file (no silent no-op)" {
  run devagent_state_set "$DEVAGENT_TMP/does-not-exist.toml" branch x
  [ "$status" -ne 0 ]
}

# --- Task 2: checklist step helpers -----------------------------------------

@test "mark_step flips a glyph and assert_step confirms it" {
  mark_step "$(CL)" 8 x
  assert_step "$(CL)" 8 x
  assert_step "$(CL)" 8 x branch
}

@test "mark_step distinguishes step 2 from step 12" {
  mark_step "$(CL)" 12 x
  assert_step "$(CL)" 12 x
  assert_step "$(CL)" 2 x        # step 2 (draft) already [x] in fixture; must stay [x]
}

@test "mark_step FAILS LOUD on an absent step" {
  run mark_step "$(CL)" 99 x
  [ "$status" -ne 0 ]
}

@test "assert_step FAILS when the glyph differs" {
  run assert_step "$(CL)" 8 x   # step 8 (branch) is [ ] in fixture
  [ "$status" -ne 0 ]
}

@test "assert_step matches the regex-special ? glyph (B1 regression)" {
  mark_step "$(CL)" 6 '?'
  assert_step "$(CL)" 6 '?'         # must MATCH the literal ? glyph
  run assert_step "$(CL)" 6 x       # and must not spuriously match x
  [ "$status" -ne 0 ]
}

@test "assert_step does not treat . as a wildcard glyph (B1 regression)" {
  run assert_step "$(CL)" 6 .       # step 6 is [ ]; literal . must NOT match
  [ "$status" -ne 0 ]
}

@test "delete_step removes a step line" {
  delete_step "$(CL)" 19
  run grep -qE '^- \[.\] +19\. ' "$(CL)"
  [ "$status" -ne 0 ]
}
