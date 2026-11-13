#!/usr/bin/env bats
# tests/disk-callers.bats — #1009: the disk issue backend's callers. The
# backend's own verbs are tests/backend-disk.bats (run by backend-contract.bats);
# this file holds what the callers do with it: the transition library, the merge
# marker, trust, pull, /devagent:file and the WBS import.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # A logging stub disk backend: one bracketed element per argv word, exit $STUB_RC.
  STUB_DIR="$BATS_TEST_TMPDIR/issue"
  STUB_LOG="$BATS_TEST_TMPDIR/backend.log"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/disk.sh" <<EOF
#!/usr/bin/env bash
line=""; for a in "\$@"; do line+="[\$a] "; done
printf '%s\n' "\${line% }" >> "$STUB_LOG"
exit "\${STUB_RC:-0}"
EOF
  chmod +x "$STUB_DIR/disk.sh"
  cp "$STUB_DIR/disk.sh" "$STUB_DIR/github.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.testproj.permissions]
transition_issue = true

[project.testproj.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
TOML
  # shellcheck source=../scripts/lib/paths.sh
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  # shellcheck source=../scripts/lib/io.sh
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  # shellcheck source=../scripts/lib/config.sh
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  # shellcheck source=../scripts/lib/transition.sh
  source "$PLUGIN_ROOT/scripts/lib/transition.sh"
}

teardown() { teardown_tmp_devagent_home; }

_unset_cfg() { python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/config.toml" "$1"; }

# ---------------------------------------------------------------- Task 1: transition.sh

@test "lib: disk is built-in, kind status, override DEVAGENT_DISK_STATUS_ON_SHIP" {
  run stage_map_builtin disk
  [ "$status" -eq 0 ]
  run stage_map_kind disk
  [ "$output" = status ]
  run stage_map_env_var disk on_ship
  [ "$output" = DEVAGENT_DISK_STATUS_ON_SHIP ]
  run stage_map_target disk testproj on_ship
  [ "$output" = "In Review" ]
  DEVAGENT_DISK_STATUS_ON_SHIP="env-disk" run stage_map_target disk testproj on_ship
  [ "$output" = "env-disk" ]
  # github_labels is a github table; disk reads issue_workflow only
  printf '%s\n' '' '[project.testproj.github_labels]' 'on_ship = "gh-only"' >> "$DA_HOME/config.toml"
  run stage_map_target disk testproj on_ship
  [ "$output" = "In Review" ]
}

@test "lib: issue_repo_label is disk for disk and Disk, the repo otherwise" {
  run issue_repo_label disk /home/someone/MARK/issues
  [ "$output" = disk ]
  run issue_repo_label Disk /home/someone/MARK/issues
  [ "$output" = disk ]
  run issue_repo_label github o/r
  [ "$output" = o/r ]
  run issue_repo_label "" o/r
  [ "$output" = o/r ]
}

@test "lib: transition_fire records an unmapped disk on_merge as landed" {
  _unset_cfg project.testproj.issue_workflow.on_merge
  transition_fire sync testproj Issue-1 on_merge disk /abs/issues 1 2>"$BATS_TEST_TMPDIR/err"
  [ "$TRANSITION_OUTCOME" = landed ]
  [ "$TRANSITION_RC" -eq 0 ]
  [ -z "$TRANSITION_TARGET" ]
  grep -qxF '[transition] [/abs/issues] [1] [on_merge] [--project] [testproj]' "$STUB_LOG"
}

@test "lib: transition_fire keeps an unmapped disk on_ship and an unmapped github on_merge as unmapped" {
  _unset_cfg project.testproj.issue_workflow.on_ship
  _unset_cfg project.testproj.issue_workflow.on_merge
  transition_fire ship testproj Issue-1 on_ship disk /abs/issues 1
  [ "$TRANSITION_OUTCOME" = unmapped ]
  transition_fire sync testproj Issue-1 on_merge github o/r 1
  [ "$TRANSITION_OUTCOME" = unmapped ]
}

@test "lib: transition_plan_note prints \"Done\" on disk, close the issue file, skipped (no tracker state mapped)" {
  run transition_plan_note testproj on_merge disk /home/someone/MARK/issues
  [ "$output" = '"Done" on disk' ]
  _unset_cfg project.testproj.issue_workflow.on_merge
  run transition_plan_note testproj on_merge disk /home/someone/MARK/issues
  [ "$output" = "close the issue file" ]
  _unset_cfg project.testproj.issue_workflow.on_ship
  run transition_plan_note testproj on_ship disk /home/someone/MARK/issues
  [ "$output" = "skipped (no tracker state mapped)" ]
  run transition_plan_note testproj on_merge github o/r
  [ "$output" = "skipped (no tracker state mapped)" ]
}

@test "lib: merge_marker_fire on disk writes landed on disk once; merge_marker_present is then 0" {
  # shellcheck source=../scripts/lib/log.sh
  source "$PLUGIN_ROOT/scripts/lib/log.sh"
  # shellcheck source=../scripts/lib/merge-marker.sh
  source "$PLUGIN_ROOT/scripts/lib/merge-marker.sh"
  local folder="$BATS_TEST_TMPDIR/MARK-$$/issues" idir="$BATS_TEST_TMPDIR/Issue-1"
  mkdir -p "$folder" "$idir"
  printf '%s\n' '' '[project.testproj.issue_source]' 'backend = "disk"' "repo = \"$folder\"" >> "$DA_HOME/config.toml"
  _unset_cfg project.testproj.issue_workflow.on_merge
  printf '%s\n' '# Issue-1 — Workflow checklist' '' '## Log' > "$idir/checklist.md"
  run merge_marker_present "$idir/checklist.md"
  [ "$status" -eq 1 ]
  merge_marker_fire sync testproj Issue-1 "$idir" ""
  [ "$TRANSITION_OUTCOME" = landed ]
  [ "$(grep -c 'Issue-1 merged → on_merge landed on disk$' "$idir/checklist.md")" -eq 1 ]
  run grep -c 'merged' "$idir/checklist.md"
  [ "$output" -eq 1 ]
  run grep -F "MARK-$$" "$idir/checklist.md"
  [ "$status" -eq 1 ]
  run merge_marker_present "$idir/checklist.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- Task 6: trust

# _trust_disk [backend-line…]: a project `dk` whose issue_source is a disk
# folder (or as the lines given), a capture draft and a policy on the host
# that scopes an unrelated GitHub repo. The env the entry points read is set.
_trust_disk() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset DEVAGENT_ISSUE_BACKEND_DIR
  FOLDER="$BATS_TEST_TMPDIR/MARK-$$/issues"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/dk"
  mkdir -p "$FOLDER" "$DEVDOC/Captures/idea" "$BATS_TEST_TMPDIR/dk-src"
  cp "$PLUGIN_ROOT/tests/fixtures/disk-issue/minimal.md" "$FOLDER/1.md"
  printf '# A captured idea\n\nBody.\n' > "$DEVDOC/Captures/idea/draft.md"
  local src_lines=("$@")
  [ "${#src_lines[@]}" -gt 0 ] || src_lines=('[project.dk.issue_source]' 'backend = "disk"' "repo = \"$FOLDER\"" 'dir_prefix = "Issue-"')
  {
    printf '%s\n' '[project.dk]' "source_dir = \"$BATS_TEST_TMPDIR/dk-src\"" "devdoc_dir = \"$DEVDOC\"" ''
    printf '%s\n' '[project.dk.permissions]' 'transition_issue = true' ''
    printf '%s\n' "${src_lines[@]}"
  } > "$DA_HOME/config.toml"
  if [ "${TRUST_POLICY:-1}" = 1 ]; then
    mkdir -p "$HOME/.config/devagent/trust"
    printf '%s\n' 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001"]' \
      > "$HOME/.config/devagent/trust/policy.toml"
  fi
  export DEVAGENT_DEVDOC_DIR="$DEVDOC" DEVAGENT_REPO_ORIGIN="$FOLDER"
}

# _folder_snap: the folder's names, sizes and checksums.
_folder_snap() { (cd "$FOLDER" && find . -exec cksum {} + 2>/dev/null | sort; ls -la .) ; }

@test "trust: pull, next and capture/file on a disk project exit 9 with the disk message and leave the folder unchanged" {
  _trust_disk
  local before ep n=0
  before="$(_folder_snap)"
  for ep in "pull.sh|dk|origin|1" "next.sh|dk" "capture/file.sh|--slug|idea|--target|origin"; do
    IFS='|' read -r -a args <<<"$ep"
    run --separate-stderr "$PLUGIN_ROOT/scripts/${args[0]}" "${args[@]:1}"
    [ "$status" -eq 9 ] || { echo "$ep: $status $stderr" >&2; false; }
    [[ "$stderr" == *"disk issue backend is not supported under a trust policy"* ]]
    [ "$(_folder_snap)" = "$before" ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
  [ ! -e "$DEVDOC/Issue-1" ]
  [ ! -e "$DEVDOC/Captures/idea/filed.toml" ]
}

@test "trust: a disk issue_source_fork alone, or backend = \"Disk\", also refuses" {
  _trust_disk '[project.dk.issue_source]' 'backend = "github"' 'repo = "other/repo"' 'dir_prefix = "Issue-"' '' \
    '[project.dk.issue_source_fork]' 'backend = "disk"' "repo = \"$BATS_TEST_TMPDIR/fork-issues\"" 'dir_prefix = "Issue-Fork-"'
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" dk
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"disk issue backend is not supported under a trust policy"* ]]
  _trust_disk '[project.dk.issue_source]' 'backend = "Disk"' "repo = \"$BATS_TEST_TMPDIR/x\"" 'dir_prefix = "Issue-"'
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" dk
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"disk issue backend is not supported under a trust policy"* ]]
}

@test "trust: the same policy does not refuse a github project with the disk message" {
  _trust_disk '[project.dk.issue_source]' 'backend = "github"' 'repo = "other/repo"' 'dir_prefix = "Issue-"'
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" dk
  [[ "$stderr" != *"disk issue backend"* ]]
}

@test "trust: with no policy a disk project passes the entry check" {
  TRUST_POLICY=0 _trust_disk
  # shellcheck source=../scripts/lib/trust.sh
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  run --separate-stderr trust_entry_check pull dk origin
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}
