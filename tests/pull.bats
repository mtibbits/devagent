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

@test "pull rejects unknown project with recovery menu (no network)" {
  run "$PLUGIN_ROOT/scripts/pull.sh" nosuchproj origin 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in config.toml"* ]]
  [[ "$output" == *"/devagent:init nosuchproj"* ]]
  # AC6: no scaffold dir created for the bogus project.
  [ ! -d "$BATS_TEST_TMPDIR/devDoc/nosuchproj" ]
}

@test "pull of a new issue clears the previous issue's per-issue keys (#98)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
mr_url = "https://example.com/pr/1"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
  grep -qE '^mr_url = ""$' "$DA_HOME/state/volk.toml"
}

@test "pull snapshots the displaced unparked issue's context (#98)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  v="$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-1.branch)"
  [ "$v" = "fix/1-old" ]
}

@test "re-pull of the active issue preserves its in-flight context (#98)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "fix/676-mid-flight"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^branch = "fix/676-mid-flight"$' "$DA_HOME/state/volk.toml"
}

@test "pull of a parked issue drops the parked flag and GCs its stale snapshot (#98 redmr MAJ-1)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = ""

[context.Issue-676]
branch = "feat/676-OLD"

[parked]
Issue-676 = true
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" parked.Issue-676
  [ "$status" -ne 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.branch
  [ "$status" -ne 0 ]
}

@test "park, re-pull, rebranch, resume cannot resurrect the pre-park context (#98 redmr MAJ-1 e2e)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/676-OLD"
  "$PLUGIN_ROOT/scripts/park.sh" volk
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/676-NEW"
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  # resume must NOT clobber the live branch with the stale snapshot,
  # whatever its exit status (pull dropped the parked flag → refusal is fine).
  grep -qE '^branch = "feat/676-NEW"$' "$DA_HOME/state/volk.toml"
}
