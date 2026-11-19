#!/usr/bin/env bats

load 'lib/bats-helpers'
load 'helpers/devdoc-sync'

setup() {
  setup_tmp_devagent_home
  DEVDOC1="$BATS_TEST_TMPDIR/devDoc/volk"
  DEVDOC2="$BATS_TEST_TMPDIR/devDoc/other"
  mkdir -p "$DEVDOC1/Issue-1" "$DEVDOC2/Issue-9"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC1"

[project.other]
devdoc_dir = "$DEVDOC2"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$DEVDOC1/Issue-1"

[parked]
"Issue-7" = true
EOF
  cat > "$DEVDOC1/Issue-1/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  2. draft
- [ ]  4. scope
EOF
  cat > "$DA_HOME/state/other.toml" <<EOF
active_issue = "Issue-9"
issue_dir = "$DEVDOC2/Issue-9"
EOF
  cat > "$DEVDOC2/Issue-9/checklist.md" <<'EOF'
- [!]  5. improve
EOF
  echo "Reason: stuck" > "$DEVDOC2/Issue-9/STUCK"
}

teardown() { teardown_tmp_devagent_home; }

@test "status volk shows that project only" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" != *"other"* ]]
}

@test "status --all shows both projects" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"other"* ]]
}

@test "status flags STUCK issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"Issue-9"* ]]
}

@test "status lists parked issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Parked: Issue-7"* ]]
}

@test "status shows current step name for active issue" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Issue-1"* ]]
  [[ "$output" == *"draft"* ]]
}

@test "status with no projects configured prints empty banner" {
  : > "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No projects configured"* ]]
}

# ---- #1148: the devDoc not-pushed line ----------------------------------------------
# _dd_repo <dir> — a devDoc repository at <dir> (subdirs a/ and b/ for two projects)
# whose seed is on a bare origin at <dir>.git.
_dd_repo() {
  git -c init.defaultBranch=main init -q --bare "$1.git"
  git -c init.defaultBranch=main init -q "$1"; _sync_ident "$1"
  mkdir -p "$1/a" "$1/b"; echo seed > "$1/seed"
  git -C "$1" add -A; git -C "$1" commit -q -m seed
  git -C "$1" remote add origin "$1.git"; git -C "$1" push -q -u origin main 2>/dev/null
}
# _dd_config <name> <devdoc_dir> <commit_devdoc>… — write config.toml for these projects.
_dd_config() {
  : > "$DA_HOME/config.toml"
  while [ "$#" -ge 3 ]; do
    printf '[project.%s]\ndevdoc_dir = "%s"\n\n[project.%s.permissions]\ncommit_devdoc = %s\n\n' "$1" "$2" "$1" "$3" >> "$DA_HOME/config.toml"
    shift 3
  done
}

@test "#1148 status: a shared repo prints once in --all, and in project mode" {
  local dd="$BATS_TEST_TMPDIR/dd" top line
  _dd_repo "$dd"
  GIT_AUTHOR_DATE='2026-11-13T00:28:00-0500' sync_commit "$dd" a/x.md x 'later'
  GIT_AUTHOR_DATE='2026-11-12T21:11:00-0500' sync_commit "$dd" b/y.md y 'older author date'
  _dd_config projA "$dd/a" true projB "$dd/b" true
  mv "$dd.git" "$dd.gone"                                            # no network: local refs only
  top="$(cd "$dd" && pwd -P)"
  line="devDoc $top: 2 commits not on origin/main, oldest 2026-11-12 21:11 -0500"
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "$line" <<< "$output")" = 1 ]
  [ "$(tail -n 1 <<< "$output")" = "$line" ]                         # after every block
  run "$PLUGIN_ROOT/scripts/status.sh" projA
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "$line" <<< "$output")" = 1 ]
}

@test "#1148 status: no line in sync or out of scope" {
  local dd="$BATS_TEST_TMPDIR/dd" off="$BATS_TEST_TMPDIR/off" top
  _dd_repo "$dd"; _dd_repo "$off"
  sync_commit "$off" a/x.md x 'unpushed, but only a commit_devdoc=false project uses it'
  _dd_config projA "$dd/a" true projC "$off/a" false
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]; ! grep -q '^devDoc ' <<< "$output" || false
  run "$PLUGIN_ROOT/scripts/status.sh" projA
  ! grep -q '^devDoc ' <<< "$output" || false
  run "$PLUGIN_ROOT/scripts/status.sh" projC
  ! grep -q '^devDoc ' <<< "$output" || false
  # leg c: projB (false) shares projA's (true) repository, so projB's view shows it
  sync_commit "$dd" a/x.md x 'unpushed'
  _dd_config projA "$dd/a" true projB "$dd/b" false
  top="$(cd "$dd" && pwd -P)"
  run "$PLUGIN_ROOT/scripts/status.sh" projB
  [[ "$output" == *"devDoc $top: 1 commits not on origin/main, oldest "* ]]
}

@test "#1148 status: branch origin lacks" {
  local dd="$BATS_TEST_TMPDIR/dd"
  _dd_repo "$dd"; git -C "$dd" checkout -q -b work
  _dd_config projA "$dd/a" true
  run "$PLUGIN_ROOT/scripts/status.sh" projA
  [ "$status" -eq 0 ]
  [[ "$output" == *"devDoc $(cd "$dd" && pwd -P): branch work is not on origin"* ]]
}

@test "#1148 status: detached devDoc" {
  local dd="$BATS_TEST_TMPDIR/dd"
  _dd_repo "$dd"; git -C "$dd" checkout -q --detach
  _dd_config projA "$dd/a" true
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"── projA ──"* ]]
  [[ "$output" == *"devDoc $(cd "$dd" && pwd -P): HEAD is detached, so the devDoc sync cannot run"* ]]
}
