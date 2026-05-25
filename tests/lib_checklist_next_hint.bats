#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  CL="$BATS_TEST_TMPDIR/checklist.md"
  cat > "$CL" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [ ]  2. scope
- [ ]  3. improve
EOF
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "next_command returns the right slash command from the checklist" {
  run checklist_next_command "$CL"
  [ "$status" -eq 0 ]
  [ "$output" = "/devagent:scope" ]
}

@test "next_command returns 'done' when all steps are checked" {
  cat > "$CL" <<'EOF'
- [x]  0. pull
- [x]  1. draft
EOF
  run checklist_next_command "$CL"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "print_next_hint asks the question on stderr by default" {
  run checklist_print_next_hint "$CL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would you like to continue on to /devagent:scope?"* ]]
}

@test "print_next_hint stays silent when DEVAGENT_CHAIN_ACTIVE=1" {
  DEVAGENT_CHAIN_ACTIVE=1 run checklist_print_next_hint "$CL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "print_next_hint announces workflow completion when done" {
  cat > "$CL" <<'EOF'
- [x]  0. pull
- [x]  1. draft
EOF
  run checklist_print_next_hint "$CL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow complete on this issue"* ]]
  [[ "$output" != *"Would you like to continue"* ]]
}
