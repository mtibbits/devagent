#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/issue.md" <<'EOF'
# gnuradio/volk#676 — Demo
- State: open
- Author: @alice

---

Body of the issue here.

---

## Comments (2)

### @bob · 2026-05-12

First comment.

### @carol · 2026-05-15

Second comment with more detail.
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  2. draft
## Log
- 2026-05-10 10:00  pull: fetched
- 2026-05-11 10:00  draft: started
- 2026-05-12 10:00  draft: revised
- 2026-05-13 10:00  scope: 1 recommendation
- 2026-05-14 10:00  improve: queued
- 2026-05-15 10:00  improve: in progress
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "catchup synthesizes issue title, current step, last 5 log entries" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-676"* ]]
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"Current step: 2 (draft)"* ]]
  [[ "$output" == *"draft: revised"* ]]
  [[ "$output" == *"improve: in progress"* ]]
  # First log line should be dropped (5-line cap)
  [[ "$output" != *"pull: fetched"* ]]
}

@test "catchup shows last 2 comments in summary form" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [[ "$output" == *"@bob"* || "$output" == *"@carol"* ]]
}

@test "catchup notes missing imPlan / actualWork without erroring" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"imPlan.md: not yet present"* ]]
  [[ "$output" == *"actualWork.md: not yet present"* ]]
}

@test "catchup accepts explicit issue arg" {
  mkdir -p "$DEVDOC/Issue-203"
  cat > "$DEVDOC/Issue-203/checklist.md" <<'EOF'
- [~]  0. pull
## Log
- 2026-05-01 09:00  pull: started
EOF
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk Issue-203
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-203"* ]]
}

@test "catchup errors when no active issue and no arg" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -ne 0 ]
}

@test "catchup shows the step_models tier for the current step when configured (#150)" {
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.step_models]
default  = "sonnet"
thinking = "opus"
EOF
  # current step is 2 (draft) → thinking class → opus
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"wants tier: opus"* ]]
}

@test "catchup shows no tier line when step_models is absent (#150)" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"wants tier"* ]]
}
