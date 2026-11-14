#!/usr/bin/env bats
# tests/disk-callers.bats — #1009: the disk issue backend's callers. The
# backend's own verbs are tests/backend-disk.bats (run by backend-contract.bats);
# this file holds what the callers do with it: the transition library, the merge
# marker, trust, pull, /devagent:file and the WBS import.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'lib/trust-fixture'

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

# _dk_project <permission-line> [toml-lines…]: a project `dk` over FOLDER (an
# issues folder whose path holds a marker no record may carry) and DEVDOC. The
# lines after the permission are the rest of the config; with none, its
# issue_source is the disk folder.
_dk_project() {
  local perm="$1"
  shift
  FOLDER="$BATS_TEST_TMPDIR/MARK-$$/issues"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/dk"
  mkdir -p "$FOLDER" "$DEVDOC" "$BATS_TEST_TMPDIR/dk-src"
  [ "$#" -gt 0 ] || set -- '[project.dk.issue_source]' 'backend = "disk"' "repo = \"$FOLDER\"" 'dir_prefix = "Issue-"'
  printf '%s\n' '[project.dk]' "source_dir = \"$BATS_TEST_TMPDIR/dk-src\"" "devdoc_dir = \"$DEVDOC\"" '' \
    '[project.dk.permissions]' "$perm" '' "$@" > "$DA_HOME/config.toml"
}

# _draft: the capture draft that /devagent:file files.
_draft() {
  mkdir -p "$DEVDOC/Captures/idea"
  printf '# A captured idea\n\nBody.\n' > "$DEVDOC/Captures/idea/draft.md"
}

# _no_mark_in <path>: no file at or under <path> names the folder.
_no_mark_in() {
  run grep -rlF "MARK-$$" "$1"
  [ "$status" -eq 1 ] || { echo "folder path leaked into: $output" >&2; return 1; }
}

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
  _no_mark_in "$idir/checklist.md"
  run merge_marker_present "$idir/checklist.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- Task 6: trust

# _trust_disk [backend-line…]: a project `dk` whose issue_source is a disk
# folder (or as the lines given), a capture draft and a policy on the host
# that scopes an unrelated GitHub repo. The env the entry points read is set.
_trust_disk() {
  trust_fixture_home
  unset DEVAGENT_ISSUE_BACKEND_DIR
  _dk_project 'transition_issue = true' "$@"
  cp "$PLUGIN_ROOT/tests/fixtures/disk-issue/minimal.md" "$FOLDER/1.md"
  _draft
  [ "${TRUST_POLICY:-1}" != 1 ] || trust_fixture_policy "$HOME/.config/devagent/trust"
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

# ---------------------------------------------------------------- Task 7: callers

# _file_disk [backend]: a project `dk` whose issue_source is a disk folder (or
# <backend> with repo o/r), push_mr false, a capture draft, and only the env
# /devagent:file is handed: the devdoc. No backend or repo env is exported.
_file_disk() {
  trust_fixture_home
  unset DEVAGENT_ISSUE_BACKEND DEVAGENT_REPO_ORIGIN DEVAGENT_REPO_FORK DEVAGENT_PERMISSION_PUSH_MR
  if [ "${1:-disk}" = disk ]; then
    _dk_project 'push_mr = false'
  else
    _dk_project 'push_mr = false' '[project.dk.issue_source]' "backend = \"$1\"" 'repo = "o/r"' 'dir_prefix = "Issue-"'
  fi
  _draft
  export DEVAGENT_DEVDOC_DIR="$DEVDOC"
}

@test "callers: file.sh on a disk project with push_mr=false and no --yes creates <N>.md and writes url = \"disk:<N>\", repo = \"disk\"" {
  _file_disk
  unset DEVAGENT_ISSUE_BACKEND_DIR
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  [ "$output" = "disk:1" ]
  [ -f "$FOLDER/1.md" ]
  grep -qx '# A captured idea' "$FOLDER/1.md"
  local f="$DEVDOC/Captures/idea/filed.toml"
  grep -qx 'issue_num = "1"' "$f"
  grep -qx 'url = "disk:1"' "$f"
  grep -qx 'repo = "disk"' "$f"
  grep -qx 'backend = "disk"' "$f"
  [ ! -e "$DEVDOC/Captures/idea/.pending" ]
  _no_mark_in "$DEVDOC/Captures/idea"
}

@test "callers: file.sh still stops at the push_mr gate for github" {
  _file_disk github
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"Permission gate: push_mr=false"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "callers: file.sh keeps an exported repo over the config's when it reads the backend from config" {
  _file_disk github
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR" DEVAGENT_PERMISSION_PUSH_MR=true DEVAGENT_REPO_ORIGIN=scratch/repo
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\necho 7\n' "$STUB_LOG" > "$STUB_DIR/github.sh"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  [[ "$(cat "$STUB_LOG")" == "create scratch/repo "* ]]
  grep -qx 'repo = "scratch/repo"' "$DEVDOC/Captures/idea/filed.toml"
}

@test "callers: a disk.sh in another backends dir is not exempt from the push_mr gate" {
  _file_disk
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"Permission gate: push_mr=false"* ]]
  [ ! -e "$STUB_LOG" ]
  _no_mark_in "$DEVDOC/Captures/idea"
}

@test "callers: file.sh --yes on a github project files to the config's repo" {
  _file_disk github
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\necho 7\n' "$STUB_LOG" > "$STUB_DIR/github.sh"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin --yes
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  [ "$output" = "https://github.com/o/r/issues/7" ]
  [[ "$(cat "$STUB_LOG")" == "create o/r "* ]]
  grep -qx 'repo = "o/r"' "$DEVDOC/Captures/idea/filed.toml"
}

@test "callers: file.sh refuses a disk id that is not a number" {
  _file_disk
  printf '#!/usr/bin/env bash\necho 1/2\n' > "$STUB_DIR/disk.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$STUB_DIR"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin --yes
  [ "$status" -eq 3 ]
  [ -e "$DEVDOC/Captures/idea/.pending" ]
  [ ! -e "$DEVDOC/Captures/idea/filed.toml" ]
}

@test "callers: a disk create the format refuses exits 3 and clears .pending" {
  _file_disk
  unset DEVAGENT_ISSUE_BACKEND_DIR
  printf '%s\n' '# A captured idea' '' '## Comments' 'not a comment' > "$DEVDOC/Captures/idea/draft.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 3 ]
  [ ! -e "$DEVDOC/Captures/idea/.pending" ]
  [ ! -e "$DEVDOC/Captures/idea/filed.toml" ]
  [ -z "$(ls "$FOLDER")" ]
  # a backend failure other than a refused prompt also clears it (nothing was written)
  rm -rf "$FOLDER" "$BATS_TEST_TMPDIR/MARK-$$"
  _draft
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 3 ]
  [ ! -e "$DEVDOC/Captures/idea/.pending" ]
}

# ---------------------------------------------------------------- Task 8: end to end

# _e2e: a project `dk` on a disk folder with the real backends, the gate open
# and the skeleton's stage mapping. FOLDER's path holds a marker no record may
# carry.
_e2e() {
  unset DEVAGENT_ISSUE_BACKEND_DIR
  _dk_project 'transition_issue = true'
  printf '%s\n' '' '[project.dk.issue_workflow]' 'on_draft_start = "In Progress"' 'on_ship = "In Review"' 'on_merge = "Done"' \
    >> "$DA_HOME/config.toml"
}

@test "e2e: pull on a disk project writes # disk#<N> — <title>, scaffolds the checklist, and logs fetched disk#<N>" {
  _e2e
  cp "$PLUGIN_ROOT/tests/fixtures/disk-issue/minimal.md" "$FOLDER/4.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" dk origin 4
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  [ "$(head -n 1 "$DEVDOC/Issue-4/issue.md")" = "# disk#4 — Add a dark-mode toggle to the settings page" ]
  grep -qx -- '- URL: disk:4' "$DEVDOC/Issue-4/issue.md"
  grep -qE '^- \[x\] +0\. pull' "$DEVDOC/Issue-4/checklist.md"
  grep -q '  pull: fetched disk#4, scaffold created$' "$DEVDOC/Issue-4/checklist.md"
  _no_mark_in "$DEVDOC/Issue-4"
}

@test "e2e: a ## Workflow flags block with tier: oneshot picks the oneshot checklist" {
  _e2e
  printf '%s\n' '# Small fix' '' '## Prompt' 'Intro.' '' '## Workflow flags' 'tier: oneshot' '' '## Motivation' 'Stuff.' > "$FOLDER/5.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" dk origin 5
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  grep -q '^Template: oneshot$' "$DEVDOC/Issue-5/checklist.md"
}

@test "e2e: the three stages through transition_fire leave status: Done, state: closed and three dated entries" {
  _e2e
  cp "$PLUGIN_ROOT/tests/fixtures/disk-issue/minimal.md" "$FOLDER/2.md"
  DEVAGENT_DATE_OVERRIDE=2026-11-10 transition_fire draft dk Issue-2 on_draft_start disk "$FOLDER" 2
  [ "$TRANSITION_OUTCOME" = landed ]
  DEVAGENT_DATE_OVERRIDE=2026-11-10 transition_fire ship dk Issue-2 on_ship disk "$FOLDER" 2
  [ "$TRANSITION_OUTCOME" = landed ]
  DEVAGENT_DATE_OVERRIDE=2026-11-11 transition_fire sync dk Issue-2 on_merge disk "$FOLDER" 2
  [ "$TRANSITION_OUTCOME" = landed ]
  grep -vx 'parent: 3' "$PLUGIN_ROOT/tests/fixtures/disk-issue/full.md" > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$FOLDER/2.md"
}

@test "e2e: wbs init --from-tracker builds three epics of five leaves" {
  _e2e
  local i p
  for i in 1 2 3; do
    printf '%s\n' "# Epic: E$i" '' '## Prompt' "Epic $i." > "$FOLDER/$i.md"
  done
  for i in $(seq 4 18); do
    p=$(( (i - 4) / 5 + 1 ))
    if [ "$i" -eq 4 ]; then
      printf '%s\n' "# Leaf $i" '' '## Prompt' 'Parent epic: my-epic disk:1' > "$FOLDER/$i.md"
    else
      printf '%s\n' "# Leaf $i" "parent: $p" '' '## Prompt' "Leaf $i." > "$FOLDER/$i.md"
    fi
  done
  run --separate-stderr "$PLUGIN_ROOT/scripts/wbs-init.sh" dk --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  # per epic, the leaves indented under it
  run python3 - "$DEVDOC/WBS.md" <<'PY'
import re, sys
counts, cur = {}, None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"^- \[.\] Epic: (E\d) ", line)
    if m:
        cur = m.group(1); counts[cur] = 0
    elif re.match(r"^  - \[.\] .*\{issue: Issue-\d+", line) and cur:
        counts[cur] += 1
    elif re.match(r"^\S", line):
        cur = None
print(sorted(counts.items()))
PY
  [ "$output" = "[('E1', 5), ('E2', 5), ('E3', 5)]" ]
  grep -q 'Leaf 4 {issue: Issue-4' "$DEVDOC/WBS.md"
  _no_mark_in "$DEVDOC/WBS.md"
}

@test "e2e: a relative issue_source.repo: wbs update reports a failed tracker lookup, and wbs init --from-tracker fails with the folder error" {
  _e2e
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.dk.issue_source.repo rel/issues
  printf '%s\n' '# dk WBS' '' '- [ ] A {issue: Issue-1}' > "$DEVDOC/WBS.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/wbs-update.sh" dk
  [[ "$output$stderr" == *"tracker lookup failed"* ]]
  [[ "$output$stderr" != *"has no state-list"* ]]
  rm "$DEVDOC/WBS.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/wbs-init.sh" dk --from-tracker --all
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"issue_source.repo must name"* ]]
  [[ "$stderr" != *"has no issue-list"* ]]
}

@test "e2e: after pull and on_merge no file under Issue-<N>/, and after file.sh none under Captures/<slug>/, contains the folder path" {
  _e2e
  # shellcheck source=../scripts/lib/log.sh
  source "$PLUGIN_ROOT/scripts/lib/log.sh"
  # shellcheck source=../scripts/lib/merge-marker.sh
  source "$PLUGIN_ROOT/scripts/lib/merge-marker.sh"
  cp "$PLUGIN_ROOT/tests/fixtures/disk-issue/minimal.md" "$FOLDER/1.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" dk origin 1
  [ "$status" -eq 0 ]
  merge_marker_fire sync dk Issue-1 "$DEVDOC/Issue-1" ""
  [ "$TRANSITION_OUTCOME" = landed ]
  grep -q 'Issue-1 merged → on_merge landed: "Done" on disk$' "$DEVDOC/Issue-1/checklist.md"
  [ "$(find "$DEVDOC/Issue-1" -type f | wc -l)" -ge 2 ]
  _no_mark_in "$DEVDOC/Issue-1"
  _draft
  DEVAGENT_DEVDOC_DIR="$DEVDOC" run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug idea --target origin
  [ "$status" -eq 0 ]
  [ "$(find "$DEVDOC/Captures/idea" -type f | wc -l)" -ge 2 ]
  _no_mark_in "$DEVDOC/Captures/idea"
}
