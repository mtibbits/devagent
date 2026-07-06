#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676" "$DEVDOC/Issue-203"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
## Log
EOF
  cat > "$DEVDOC/Issue-203/checklist.md" <<'EOF'
- [~]  3. improve
## Log
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "park marks active issue [P] and clears active_issue" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  # active_issue should no longer be Issue-676 (key removed or empty)
  run grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  [ "$status" -ne 0 ]
  # Issue-676 must appear under [parked] table as `Issue-676 = true`
  grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
  # Either the [P] mark on step 1, or a "park: ..." log entry
  grep -E '^- \[P\] +1\. draft' "$DEVDOC/Issue-676/checklist.md" \
    || grep -q 'park: ' "$DEVDOC/Issue-676/checklist.md"
}

@test "park with explicit issue parks that one even if not active" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^Issue-203 *= *true' "$DA_HOME/state/volk.toml"
  # Active issue not changed
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
}

@test "resume reactivates a parked issue" {
  "$PLUGIN_ROOT/scripts/park.sh" volk
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  run grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
  [ "$status" -ne 0 ]
}

@test "resume errors when issue isn't parked" {
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-999
  [ "$status" -ne 0 ]
  [[ "$output" == *"not parked"* || "$output" == *"unknown"* ]]
}

@test "switch parks current and resumes target" {
  # Park 203 so it's resumable
  "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-203"' "$DA_HOME/state/volk.toml"
  grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
}

@test "switch refuses an unparked target WITHOUT parking the current issue (#142)" {
  # Issue-203 exists but is NOT parked → switch must die before parking 676,
  # leaving no half-applied switch.
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-203
  [ "$status" -ne 0 ]
  # current issue still active and NOT freshly parked
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  run grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
  [ "$status" -ne 0 ]
}

@test "switch refuses a parked target whose dir is missing, leaving current intact (#142)" {
  "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  rm -rf "$DEVDOC/Issue-203"
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-203
  [ "$status" -ne 0 ]
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  run grep -qE '^Issue-676 *= *true' "$DA_HOME/state/volk.toml"
  [ "$status" -ne 0 ]
}

@test "park errors when no active issue and no arg" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -ne 0 ]
}

@test "park refuses a typo'd issue id whose dir is missing (A21)" {
  # A non-existent issue dir used to be parked anyway: marking was skipped but
  # the parked entry was still written, stranding junk in [parked].
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-99999
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  # No stranded parked entry was written.
  run grep -qE '^Issue-99999 *= *true' "$DA_HOME/state/volk.toml"
  [ "$status" -ne 0 ]
}

@test "resume restores the parked issue's branch/baseline/mr_url, not the interloper's (#98)" {
  # Issue-676 is active with a branch (parked after its branch step).
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "fix/676-foo"
baseline_sha = "aaa111"
mr_url = "https://example.com/pr/676"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  # Interloper issue 203 takes over and sets its own context.
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/203-bar"
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" baseline_sha "bbb222"
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^branch = "fix/676-foo"$'  "$DA_HOME/state/volk.toml"
  grep -qE '^baseline_sha = "aaa111"$' "$DA_HOME/state/volk.toml"
  grep -qE '^mr_url = "https://example.com/pr/676"$' "$DA_HOME/state/volk.toml"
}

@test "park clears per-issue keys so a new issue starts clean (#98)" {
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "fix/676-foo"
mr_url = "https://example.com/pr/676"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
  grep -qE '^mr_url = ""$' "$DA_HOME/state/volk.toml"
}

@test "park of a non-active issue leaves the active issue's context alone (#98)" {
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "fix/676-foo"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^branch = "fix/676-foo"$' "$DA_HOME/state/volk.toml"
}

@test "resume of a legacy-parked issue (no snapshot) resets keys and warns (#98)" {
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "feat/203-bar"

[parked]
Issue-676 = true
CTX
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/state/volk.toml" active_issue
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" == *"no saved context"* ]]   # bats `run` folds stderr into $output
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
}

@test "resume over a live unparked issue snapshots the displaced issue's context (#98 review M2)" {
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "fix/676-foo"
CTX
  # Park 203 (non-active), then resume it while 676 is still active+unparked.
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-203
  [ "$status" -eq 0 ]
  v="$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.branch)"
  [ "$v" = "fix/676-foo" ]
}

@test "resume of an already-active issue is a no-op on context (#98 redmr MAJ-1 legacy guard)" {
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "feat/676-NEW"

[context.Issue-676]
branch = "feat/676-OLD"

[parked]
Issue-676 = true
CTX
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^branch = "feat/676-NEW"$' "$DA_HOME/state/volk.toml"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" parked.Issue-676
  [ "$status" -ne 0 ]
}

@test "resume warns when the restored worktree_path no longer exists on disk (#248)" {
  # Issue-676 parked with a worktree that is removed out-of-band before resume.
  local dead="$BATS_TEST_TMPDIR/gone-worktree"
  cat >> "$DA_HOME/state/volk.toml" <<CTX
branch = "fix/676-foo"
worktree_path = "$dead"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  # The worktree dir never exists ($dead) — resume must warn, naming path + issue,
  # and still resume (rc 0).
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"$dead"* ]]        # names the dead path
  [[ "$output" == *"Issue-676"* ]]    # names the issue
  [[ "$output" == *"worktree"* ]]     # signals the worktree is the problem
}

@test "resume does NOT warn when worktree_path points at a live git tree (#248)" {
  local live="$BATS_TEST_TMPDIR/live-worktree"
  mkdir -p "$live"
  git -C "$live" init -q
  cat >> "$DA_HOME/state/volk.toml" <<CTX
branch = "fix/676-foo"
worktree_path = "$live"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]      # live tree → no spurious warning
  [[ "$output" == *"resumed Issue-676"* ]]
}

@test "resume promotes and restores in ONE state transaction (#317)" {
  # The promote-before-restore window: HEAD flipped active_issue first, then
  # state_context_restore repopulated the top level across ~12 more
  # transactions — a crash (or the table-miss fallback under a concurrent
  # reader) inside the window pairs the NEW active_issue with the OLD issue's
  # top-level keys. Pin the fix by observing the _toml.py traffic itself:
  # the mutation that writes active_issue must carry the restored per-issue
  # keys in the SAME transaction.
  cat >> "$DA_HOME/state/volk.toml" <<'CTX'
branch = "fix/676-foo"
CTX
  run "$PLUGIN_ROOT/scripts/park.sh" volk          # snapshot + park (no shim)
  [ "$status" -eq 0 ]
  # Shim python3 to log every _toml.py argv, then exec the real interpreter.
  REAL_PY="$(command -v python3)"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/python3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/toml-calls.log"
exec "$REAL_PY" "\$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/shim/python3"
  : > "$BATS_TEST_TMPDIR/toml-calls.log"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  # 1. The fused transaction: the mutation carrying active_issue also carries
  #    the restored branch and the rest of the per-issue keys.
  fused="$(grep ' active_issue ' "$BATS_TEST_TMPDIR/toml-calls.log" | grep ' set-many ')"
  [ -n "$fused" ]
  [[ "$fused" == *" branch fix/676-foo"* ]]
  [[ "$fused" == *" worktree_path "* ]]
  # 2. Coarse cap: the whole unpinned resume stays a handful of mutations
  #    (HEAD's choreography was ~12+: promote, clear x7, per-key sets, unset,
  #    updated_at). Generous headroom so refactors don't flake.
  muts="$(awk '{print $2}' "$BATS_TEST_TMPDIR/toml-calls.log" | grep -cE '^(set|set-int|set-bool|set-many|set-many-if|set-if|unset)$')"
  [ "$muts" -le 6 ]
  # 3. Behavioral: the branch is restored.
  grep -qE '^branch = "fix/676-foo"$' "$DA_HOME/state/volk.toml"
}
