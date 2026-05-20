#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"

  # Config with both origin and fork issue sources
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.issue_source_fork]
backend = "github"
repo = "mtibbits/volk"
dir_prefix = "Issue-Fork-"
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "pull origin scaffolds Issue-N dir and writes issue.md" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-676" ]
  [ -f "$DEVDOC/Issue-676/issue.md" ]
  [ -f "$DEVDOC/Issue-676/checklist.md" ]
  grep -q "gnuradio/volk#676" "$DEVDOC/Issue-676/issue.md"
}

@test "pull fork uses dir_prefix Issue-Fork-" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk fork 42
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-Fork-42" ]
}

@test "pull marks step 0 done in checklist" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E '^\- \[x\] +0\. pull' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull appends a log entry naming the source and issue" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E 'pull: fetched gnuradio/volk#676' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull sets state.active_issue and state.issue_dir" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q 'active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  grep -q "issue_dir *= *\"$DEVDOC/Issue-676\"" "$DA_HOME/state/volk.toml"
}

@test "pull is idempotent on issue.md (refetch overwrites, checklist preserved)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  # Tamper with the checklist so we can prove it wasn't blown away
  printf '\nUSER-EDIT\n' >> "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q "USER-EDIT" "$DEVDOC/Issue-676/checklist.md"
}

@test "pull rejects missing origin|fork token" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk 676
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin|fork"* ]]
}

@test "pull rejects non-numeric issue number" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin notanumber
  [ "$status" -ne 0 ]
}
