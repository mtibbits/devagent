#!/usr/bin/env bats
#
# #703: `wbs update` sets issue-leaf glyphs from the tracker first, local
# checklists second. Backends are the stub in tests/fixtures/wbs-tracker
# (per-repo list files, see its header) except in the "real backend" tests,
# which run scripts/issue/{github,gitlab,jira}.sh over the recorded or
# doc-derived fixtures. gh/glab/curl shims on PATH log to network.log, which
# teardown asserts absent.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"
load lib/fixture-server.sh

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV" "$TMPROOT/src"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"
  _config github acme/testproj yes

  export TMPROOT
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
  unset DEVAGENT_WBS_OFFLINE DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_GITHUB_LABEL_IN_PROGRESS \
    DEVAGENT_GITLAB_LABELS_IN_PROGRESS DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS DEVAGENT_PROJECT
}

teardown() {
  if declare -F fixture_stop >/dev/null 2>&1; then fixture_stop; fi
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

# _config <origin-backend|none> <origin-repo> <fork: yes|no|noprefix|short>
# (short: a github fork whose dir_prefix is "Issue-F"; same: one whose
# dir_prefix equals the origin's, a misconfiguration; #792)
_config() {
  local ob="$1" orepo="$2" fork="$3"
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' '' \
      '[project.testproj]' "source_dir = \"$TMPROOT/src\"" "devdoc_dir = \"$TMPDEV\""
    if [ "$ob" != none ]; then
      printf '%s\n' '' '[project.testproj.issue_source]' "backend = \"$ob\"" \
        "repo = \"$orepo\"" 'dir_prefix = "Issue-"'
    fi
    case "$fork" in
      yes) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' 'dir_prefix = "Issue-Fork-"' ;;
      noprefix) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' ;;
      short) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' 'dir_prefix = "Issue-F"' ;;
      same) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' 'dir_prefix = "Issue-"' ;;
    esac
  } > "$HOME/.claude/devagent/config.toml"
}

# _cl <issue-id> done|progress|pending: write the issue's checklist.
_cl() {
  mkdir -p "$TMPDEV/$1"
  case "$2" in
    done)     printf '%s\n' '- [x]  0. pull' '- [x] 23. cleanup' ;;
    progress) printf '%s\n' '- [x]  0. pull' '- [ ] 23. cleanup' ;;
    pending)  printf '%s\n' '- [ ]  0. pull' '- [ ] 23. cleanup' ;;
  esac > "$TMPDEV/$1/checklist.md"
}

# _list <repo> <line>...: the stub github state-list output for <repo>.
_list() {
  local repo="$1"; shift
  printf '%s\n' "$@" > "$TMPROOT/state-list.github.${repo//\//_}"
}

# _list_on <backend> <repo> <line>...: the stub state-list output for <repo>
# on a backend other than github (#792).
_list_on() {
  local backend="$1" repo="$2"
  shift 2
  printf '%s\n' "$@" > "$TMPROOT/state-list.$backend.${repo//\//_}"
}

# _key_form_leg [--offline]: a WBS whose only leaf names PROJ-12 in key form;
# active Issue-12 is present (no second leaf), active Issue-13 is added.
_key_form_leg() {
  _config jira PROJ no
  _list_on jira PROJ $'PROJ-12\tin_progress'
  printf '%s\n' '# testproj WBS' '' '- [ ] Twelve {issue: Issue-PROJ-12, est: 1w}' > "$TMPDEV/WBS.input"
  cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  _active Issue-12
  _update "$@"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run grep -c Unassigned "$TMPDEV/WBS.md"
  [ "$output" = "0" ]
  run grep -c '{issue: Issue-12,' "$TMPDEV/WBS.md"
  [ "$output" = "0" ]
  # positive control: an issue no leaf names is added once
  cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  _active Issue-13
  _update "$@"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run grep -c Unassigned "$TMPDEV/WBS.md"
  [ "$output" = "1" ]
  run grep -c '{issue: Issue-13, est: ?w' "$TMPDEV/WBS.md"
  [ "$output" = "1" ]
}

# _list_fail <repo> <rc> <stderr>: the stub's state-list for <repo> fails.
_list_fail() {
  local f="$TMPROOT/state-list.github.${1//\//_}"
  [ -f "$f" ] || : > "$f"
  printf '%s\n' "$2" > "$f.rc"
  printf '%s\n' "$3" > "$f.err"
}

_active() {
  printf 'active_issue = "%s"\n' "$1" > "$HOME/.claude/devagent/state/testproj.toml"
}

_update() {
  run bash "$REPO/scripts/wbs.sh" update testproj "$@"
}

# Run update and diff WBS.md against $TMPDEV/expected.
_update_diff() {
  _update "$@"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  diff "$TMPDEV/expected" "$TMPDEV/WBS.md"
}

# PATH without the shim dir and without any dir holding one of the commands.
_path_without() {
  local IFS=: d c out="" skip
  for d in $PATH; do
    [ "$d" = "$TMPROOT/shims" ] && continue
    skip=0
    for c in "$@"; do
      if [ -x "$d/$c" ] || [ -x "$d/$c.exe" ]; then skip=1; fi
    done
    [ "$skip" -eq 1 ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

M2_TAIL="no glyph changed. Run 'wbs update --offline' (or set DEVAGENT_WBS_OFFLINE=1) to reconcile from local checklists only."

@test "tracker done and not_planned override every local glyph (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [P] One {issue: Issue-1, est: 1w}
- [!] Two {issue: Issue-2, est: 1w}
- [~] Three {issue: Issue-3, est: 1w}
- [ ] Four {issue: Issue-4, est: 1w}
EOF
  local i
  for i in 1 2 3 4; do _cl "Issue-$i" progress; done
  _list acme/testproj $'1\tdone' $'2\tdone' $'3\tnot_planned' $'4\tnot_planned'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] One {issue: Issue-1, est: 1w, status_src: tracker}
- [x] Two {issue: Issue-2, est: 1w, status_src: tracker}
- [-] Three {issue: Issue-3, est: 1w, status_src: tracker}
- [-] Four {issue: Issue-4, est: 1w, status_src: tracker}
EOF
  _update_diff
}

@test "tracker in_progress sets [~] but keeps hand-set [P] [!] [?] (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [x] One {issue: Issue-1, est: 1w}
- [ ] Two {issue: Issue-2, est: 1w}
- [P] Three {issue: Issue-3, est: 1w}
- [!] Four {issue: Issue-4, est: 1w}
- [?] Five {issue: Issue-5, est: 1w}
EOF
  local i
  for i in 1 2 3 4 5; do _cl "Issue-$i" "done"; done
  _list acme/testproj $'1\tin_progress' $'2\tin_progress' $'3\tin_progress' \
    $'4\tin_progress' $'5\tin_progress'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] One {issue: Issue-1, est: 1w, status_src: tracker}
- [~] Two {issue: Issue-2, est: 1w, status_src: tracker}
- [P] Three {issue: Issue-3, est: 1w}
- [!] Four {issue: Issue-4, est: 1w}
- [?] Five {issue: Issue-5, est: 1w}
EOF
  _update_diff
}

@test "tracker open falls through to the checklist; all-done gives [~] (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Progress {issue: Issue-1, est: 1w}
- [x] No progress {issue: Issue-2, est: 1w}
- [ ] All done {issue: Issue-3, est: 1w}
- [x] No checklist {issue: Issue-4, est: 1w}
- [x] Reopened {issue: Issue-5, est: 1w, status_src: tracker}
EOF
  _cl Issue-1 progress
  _cl Issue-2 pending
  _cl Issue-3 "done"
  _list acme/testproj $'1\topen' $'2\topen' $'3\topen' $'4\topen' $'5\topen'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] Progress {issue: Issue-1, est: 1w, status_src: checklist}
- [ ] No progress {issue: Issue-2, est: 1w, status_src: checklist}
- [~] All done {issue: Issue-3, est: 1w, status_src: tracker}
- [x] No checklist {issue: Issue-4, est: 1w}
- [~] Reopened {issue: Issue-5, est: 1w, status_src: tracker}
EOF
  _update_diff
}

@test "a leaf missing from the list keeps its glyph and is reported once (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Listed {issue: Issue-1, est: 1w}
- [~] Missing one {issue: Issue-8, est: 1w}
- [P] Missing two {issue: Issue-9, est: 1w}
EOF
  _cl Issue-8 "done"
  _list acme/testproj $'1\tdone'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Listed {issue: Issue-1, est: 1w, status_src: tracker}
- [~] Missing one {issue: Issue-8, est: 1w}
- [P] Missing two {issue: Issue-9, est: 1w}
EOF
  _update_diff
  run grep -c 'not found on github acme/testproj' <<< "$output"
  [ "$output" = "2" ]
  [[ "$(cat "$TMPDEV/WBS.md")" != *"Issue-8, est: 1w, status_src"* ]]
}

@test "the not-found message names the leaf, the backend and the repo (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] Missing {issue: Issue-8, est: 1w}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'1\tdone'
  _update
  [ "$status" -eq 0 ]
  [[ "$output" == *"wbs update: Issue-8 not found on github acme/testproj; glyph unchanged"* ]]
}

@test "a failed lookup aborts the tracker phase: no glyph changes, one warning, exit 0 (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] One {issue: Issue-1, est: 1w}
- [ ] Two {issue: Issue-2, est: 1w}
EOF
  _cl Issue-2 "done"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _list acme/testproj $'1\tdone'
  _list_fail acme/testproj 1 'HTTP 401'
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  run grep -c 'WARNING: tracker lookup failed' <<< "$output"
  [ "$output" = "1" ]
  _update
  [[ "$output" == *"wbs update: WARNING: tracker lookup failed for github acme/testproj (exit 1: HTTP 401); $M2_TAIL"* ]]
  # positive control: the same list with rc 0 does change the file
  rm -f "$TMPROOT/state-list.github.acme_testproj.rc" "$TMPROOT/state-list.github.acme_testproj.err"
  _update
  [ "$status" -eq 0 ]
  run cmp -s "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  [ "$status" -eq 1 ]
  grep -qxF -- '- [x] One {issue: Issue-1, est: 1w, status_src: tracker}' "$TMPDEV/WBS.md"
}

@test "malformed state-list output aborts the tracker phase (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] Five {issue: Issue-5, est: 1w}' > "$TMPDEV/WBS.md"
  _cl Issue-5 "done"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _list acme/testproj $'5\tclosed'
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  run grep -c 'WARNING: tracker lookup failed' <<< "$output"
  [ "$output" = "1" ]
  _update
  [[ "$output" == *"tracker lookup failed for github acme/testproj (malformed line 1: 5"$'\t'"closed); "* ]]
}

@test "one failing source aborts the phase for both sources (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Origin {issue: Issue-1, est: 1w}
- [ ] Fork {issue: Issue-Fork-2, est: 1w}
EOF
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _list acme/testproj $'1\tdone'
  _list me/testproj-fork $'2\tdone'
  _list_fail me/testproj-fork 1 'HTTP 502'
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  run grep -c 'WARNING: tracker lookup failed for github me/testproj-fork (exit 1: HTTP 502)' <<< "$output"
  [ "$output" = "1" ]
}

@test "auto-add on abort falls back to the local checklist (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _active Issue-7
  _cl Issue-7 "done"
  _list acme/testproj $'7\tin_progress'
  _list_fail acme/testproj 1 'HTTP 401'
  { cat "$TMPDEV/WBS.input"
    printf '%s\n' '- [ ] Unassigned' '  - [x] Issue-7 {issue: Issue-7, est: ?w, status_src: checklist}'
  } > "$TMPDEV/expected"
  _update_diff
  # second leg: no checklist -> [ ] with no status_src
  cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  rm -rf "$TMPDEV/Issue-7"
  { cat "$TMPDEV/WBS.input"
    printf '%s\n' '- [ ] Unassigned' '  - [ ] Issue-7 {issue: Issue-7, est: ?w}'
  } > "$TMPDEV/expected"
  _update_diff
}

@test "no tracker configured keeps the pre-#703 checklist rule (#703)" {
  _config none "" no
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _cl Issue-1 "done"
  printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
  _update_diff
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "a backend without state-list uses local checklists (#703)" {
  _config github acme/testproj no
  local leg
  for leg in 78 2 noscript; do
    printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
    _cl Issue-1 "done"
    case "$leg" in
      78) : ;;  # no list file: the stub exits 78
      2) printf '#!/usr/bin/env bash\nexit 2\n' > "$DEVAGENT_ISSUE_BACKEND_DIR/github.sh" ;;
      noscript) rm -f "$DEVAGENT_ISSUE_BACKEND_DIR/github.sh" ;;
    esac
    printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
    _update_diff
    run grep -c 'wbs update: github has no state-list' <<< "$output"
    [ "$output" = "1" ] || { echo "leg $leg"; false; }
  done
  _update
  [[ "$output" == *"wbs update: github has no state-list (no script); Issue- leaves use local checklists"* ]]
  [[ "$output" != *WARNING* ]]
}

@test "the no-lookup message names the exit code (#703)" {
  _config github acme/testproj no
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _update
  [ "$status" -eq 0 ]
  [[ "$output" == *"wbs update: github has no state-list (exit 78); Issue- leaves use local checklists"* ]]
}

@test "--offline makes no backend call (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _cl Issue-1 "done"
  _list acme/testproj $'1\topen'
  printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
  _update_diff --offline
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "fork leaves resolve against issue_source_fork (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Origin five {issue: Issue-5, est: 1w}
- [ ] Fork five {issue: Issue-Fork-5, est: 1w}
- [ ] Other scheme {issue: Task-5, est: 1w}
EOF
  _cl Task-5 progress
  _list acme/testproj $'5\tdone'
  _list me/testproj-fork $'5\tin_progress'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Origin five {issue: Issue-5, est: 1w, status_src: tracker}
- [~] Fork five {issue: Issue-Fork-5, est: 1w, status_src: tracker}
- [ ] Other scheme {issue: Task-5, est: 1w}
EOF
  _update_diff
  # a fork table with no dir_prefix is not a source: Issue-Fork-5 falls under
  # the origin's Issue- prefix, whose id grammar rejects "Fork-5" (no message)
  _config github acme/testproj noprefix
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Origin five {issue: Issue-5, est: 1w}
- [ ] Fork five {issue: Issue-Fork-5, est: 1w}
EOF
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Origin five {issue: Issue-5, est: 1w, status_src: tracker}
- [ ] Fork five {issue: Issue-Fork-5, est: 1w}
EOF
  _update_diff
  [[ "$output" != *"not found"* ]]
}

@test "one state-list call per source per run (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] A {issue: Issue-1, est: 1w}
- [ ] B {issue: Issue-2, est: 1w}
- [ ] C {issue: Issue-3, est: 1w}
- [ ] D {issue: Issue-Fork-1, est: 1w}
- [ ] E {issue: Issue-Fork-2, est: 1w}
- [ ] F {issue: Issue-Fork-3, est: 1w}
EOF
  _list acme/testproj $'1\tdone' $'2\topen' $'3\tin_progress'
  _list me/testproj-fork $'1\tdone' $'2\topen' $'3\tin_progress'
  _update
  [ "$status" -eq 0 ]
  run wc -l < "$TMPROOT/backend.log"
  [ "$output" -eq 2 ]
  grep -qxF '[state-list] [acme/testproj] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  grep -qxF '[state-list] [me/testproj-fork] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  run grep -c '^\[state\]' "$TMPROOT/backend.log"
  [ "$status" -eq 1 ]
}

@test "provenance: only glyph and status_src bytes change; a second run is a no-op (#703)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
<!-- note -->
# testproj WBS

Prose that must survive.

- [ ] Compact {issue: Issue-1,est:1w}
  Note under the leaf.
EOF
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _list acme/testproj $'1\tdone'
  python3 "$REPO/tests/helpers/wbs_bytes.py" patch-leaf \
    "$TMPDEV/WBS.input" "$TMPDEV/expected" "Compact" x tracker
  grep -qxF -- '- [x] Compact {issue: Issue-1,est:1w, status_src: tracker}' "$TMPDEV/expected"
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
}

@test "auto-add takes the tracker class (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _active Issue-7
  _list acme/testproj $'1\topen' $'7\tin_progress'
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' \
    '- [ ] Unassigned' '  - [~] Issue-7 {issue: Issue-7, est: ?w, status_src: tracker}' \
    > "$TMPDEV/expected"
  _update_diff
}

@test "real github backend: each recorded class sets its glyph (#703)" {
  _config github acme/testproj no
  unset DEVAGENT_ISSUE_BACKEND_DIR
  mkdir -p "$TMPROOT/ghbin"
  cp "$REPO/tests/fixtures/gh-stub" "$TMPROOT/ghbin/gh"
  chmod +x "$TMPROOT/ghbin/gh"
  export PATH="$TMPROOT/ghbin:$PATH"   # the shim dir stays: a stray curl is caught
  export GH_STUB_ISSUE_LIST_FILE="$REPO/tests/fixtures/issue-github/state-list.json"
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Completed {issue: Issue-702, est: 1w}
- [ ] Not planned {issue: Issue-701, est: 1w}
- [ ] Duplicate {issue: Issue-700, est: 1w}
- [ ] Labelled {issue: Issue-756, est: 1w}
- [ ] Open all done {issue: Issue-753, est: 1w}
- [ ] Closed no reason {issue: Issue-692, est: 1w}
EOF
  _cl Issue-753 "done"
  _cl Issue-692 "done"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Completed {issue: Issue-702, est: 1w, status_src: tracker}
- [-] Not planned {issue: Issue-701, est: 1w, status_src: tracker}
- [-] Duplicate {issue: Issue-700, est: 1w, status_src: tracker}
- [~] Labelled {issue: Issue-756, est: 1w, status_src: tracker}
- [~] Open all done {issue: Issue-753, est: 1w, status_src: tracker}
- [x] Closed no reason {issue: Issue-692, est: 1w, status_src: checklist}
EOF
  _update_diff
}

@test "real gitlab backend: closed, labelled and open issues (#703)" {
  _config gitlab foo/bar no
  unset DEVAGENT_ISSUE_BACKEND_DIR
  PATH="$(_path_without)"
  export PATH
  fixture_start "$REPO/tests/fixtures/gitlab"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4" GITLAB_TOKEN=dummy-token
  export DEVAGENT_GITLAB_LABELS_IN_PROGRESS="status::in-progress"
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Closed {issue: Issue-1, est: 1w}
- [ ] Labelled {issue: Issue-2, est: 1w}
- [ ] Open with progress {issue: Issue-3, est: 1w}
EOF
  _cl Issue-3 progress
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Closed {issue: Issue-1, est: 1w, status_src: tracker}
- [~] Labelled {issue: Issue-2, est: 1w, status_src: tracker}
- [~] Open with progress {issue: Issue-3, est: 1w, status_src: checklist}
EOF
  _update_diff
}

@test "real jira backend: Issue-N reads key <project>-N; resolutions map (#703)" {
  _config jira PROJ no
  unset DEVAGENT_ISSUE_BACKEND_DIR
  PATH="$(_path_without)"
  export PATH
  fixture_start "$REPO/tests/fixtures/jira"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL" JIRA_USER=dummy@example.com JIRA_TOKEN=dummy-token
  export DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS="Won't Do"
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Done {issue: Issue-1, est: 1w}
- [ ] Won't do, listed {issue: Issue-2, est: 1w}
- [ ] Duplicate, unlisted {issue: Issue-3, est: 1w}
- [ ] In progress {issue: Issue-4, est: 1w}
- [ ] New {issue: Issue-5, est: 1w}
- [ ] By key {issue: Issue-PROJ-2, est: 1w}
EOF
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Done {issue: Issue-1, est: 1w, status_src: tracker}
- [-] Won't do, listed {issue: Issue-2, est: 1w, status_src: tracker}
- [x] Duplicate, unlisted {issue: Issue-3, est: 1w, status_src: tracker}
- [~] In progress {issue: Issue-4, est: 1w, status_src: tracker}
- [ ] New {issue: Issue-5, est: 1w}
- [-] By key {issue: Issue-PROJ-2, est: 1w, status_src: tracker}
EOF
  _update_diff
  # DEVAGENT_JIRA_PROJECT_KEY names the key prefix (the cmd_create expression)
  export DEVAGENT_JIRA_PROJECT_KEY=ALT
  printf '%s\n' '# testproj WBS' '' '- [ ] Alt {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  printf '%s\n' '# testproj WBS' '' '- [x] Alt {issue: Issue-1, est: 1w, status_src: tracker}' > "$TMPDEV/expected"
  _update_diff
}

@test "DEVAGENT_WBS_OFFLINE=1 behaves as --offline (#703)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _cl Issue-1 "done"
  _list acme/testproj $'1\topen'
  printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
  export DEVAGENT_WBS_OFFLINE=1
  _update_diff
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "a missing backend CLI is no-lookup, not failure (#703)" {
  _config github acme/testproj no
  unset DEVAGENT_ISSUE_BACKEND_DIR
  local stripped
  stripped="$(_path_without gh)"
  # Probe before applying: where gh shares /usr/bin (GitHub runners), the
  # stripped PATH also loses rm, and teardown runs under the test's PATH.
  (PATH="$stripped"; command -v python3 >/dev/null) || skip "gh shares a PATH dir with python3 here"
  PATH="$stripped"
  export PATH
  run command -v gh
  [ "$status" -ne 0 ]
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _cl Issue-1 "done"
  printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
  _update_diff
  run grep -c 'wbs update: github has no state-list (gh not on PATH)' <<< "$output"
  [ "$output" = "1" ]
  _update
  [[ "$output" != *WARNING* ]]
}

@test "a key-form leaf names the active issue: no second leaf, online (#792)" {
  _key_form_leg
}

@test "a key-form leaf names the active issue: no second leaf, --offline (#792)" {
  _key_form_leg --offline
}

@test "the worked-example leaves take their glyph from the codec's source (#792)" {
  _config jira PROJ short
  _list_on jira PROJ $'FOO-1\tdone' $'PROJ-12\tin_progress'
  _list me/testproj-fork $'7\tnot_planned'
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Foo {issue: Issue-FOO-1, est: 1w}
- [ ] Seven {issue: Issue-F7, est: 1w}
- [ ] Twelve {issue: Issue-12, est: 1w}
- [ ] Key {issue: Issue-PROJ-12, est: 1w}
EOF
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Foo {issue: Issue-FOO-1, est: 1w, status_src: tracker}
- [-] Seven {issue: Issue-F7, est: 1w, status_src: tracker}
- [~] Twelve {issue: Issue-12, est: 1w, status_src: tracker}
- [~] Key {issue: Issue-PROJ-12, est: 1w, status_src: tracker}
EOF
  _update_diff
  [[ "$output" != *"not found"* ]]
}

@test "a prefixed leaf of the wrong shape gives no signal; --offline keeps the checklist rule (#792)" {
  _config github acme/testproj no
  printf '%s\n' '# testproj WBS' '' '- [ ] Todo {issue: Issue-TODO, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _cl Issue-TODO progress
  _list acme/testproj $'1\tdone'
  _update
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  [[ "$output" != *"not found"* ]]
  printf '%s\n' '# testproj WBS' '' '- [~] Todo {issue: Issue-TODO, est: 1w, status_src: checklist}' > "$TMPDEV/expected"
  _update_diff --offline
}

@test "equal dir_prefixes: update reads the origin, as wbs init does (#792)" {
  # wbs-import.py lists origin first; parse_leaf keeps input order on a tie
  _config github acme/testproj same
  _list acme/testproj $'1\tdone'
  _list me/testproj-fork $'1\tnot_planned'
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  printf '%s\n' '# testproj WBS' '' '- [x] One {issue: Issue-1, est: 1w, status_src: tracker}' > "$TMPDEV/expected"
  _update_diff
}

@test "DEVAGENT_JIRA_PROJECT_KEY has one home outside the backends (#792)" {
  # wbs-tracker.py `jira_keyprefix` is the one reader outside scripts/issue/
  run git -C "$REPO" grep -n DEVAGENT_JIRA_PROJECT_KEY -- scripts ':!scripts/issue'
  [ "$status" -eq 0 ] || { echo "no hit: the guard measures nothing"; false; }
  local hits="$output"
  run grep -vc '^scripts/lib/wbs-tracker.py:' <<< "$hits"
  [ "$output" = "0" ] || { echo "$hits"; false; }
}

# _phrase_count <file>: lines of the fall-through phrase in <file>, with comment
# markers stripped and whitespace collapsed, so a reflow cannot break the pin.
_phrase_count() {
  sed 's/^# \{0,1\}//' "$1" | tr -s ' \n' ' ' | grep -cF 'falls through to the next shorter' || true
}

@test "docs: every home states the fall-through rule (#792)" {
  # planted control: the pipeline finds the phrase across a wrapped comment
  printf '%s\n' '# a rest of the wrong shape falls' '#   through to the next' '# shorter dir_prefix' > "$TMPROOT/control"
  run _phrase_count "$TMPROOT/control"
  [ "$output" = "1" ]
  sed -n '/^### 13\.2 /,/^### 13\.3 /p' "$REPO/docs/specs/2026-05-19-devagent-plugin-design.md" > "$TMPROOT/spec"
  sed -n '1,/^set -euo pipefail/p' "$REPO/scripts/wbs-update.sh" > "$TMPROOT/header"
  local home
  for home in "$TMPROOT/spec" "$REPO/commands/wbs.md" "$TMPROOT/header"; do
    [ -s "$home" ] || { echo "empty home: $home"; false; }
    run _phrase_count "$home"
    [ "$output" -ge 1 ] || { echo "no fall-through rule in $home"; false; }
  done
}

# --- #780: wbs-exclude lines keep the active issue out of the auto-add ---------

# _not_added <id> <line>: the one line update prints instead of adding <id>.
_not_added() {
  printf 'wbs update: %s is listed in a wbs-exclude line (line %s); not added. Remove it from every wbs-exclude line that lists it to track it in the WBS.\n' "$1" "$2"
}

@test "Jira key form: wbs-exclude Issue-PROJ-12 keeps active Issue-12 out (#780)" {
  local out
  _config jira PROJ no
  _list_on jira PROJ $'PROJ-12\topen'
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-PROJ-12 -->' > "$TMPDEV/WBS.md"
  _active Issue-12
  _update
  out="$output"
  [ "$status" -eq 0 ] || { echo "$out"; false; }
  [ "$(grep -c Unassigned "$TMPDEV/WBS.md")" = 0 ]
  [ "$(grep -cxF "$(_not_added Issue-12 3)" <<<"$out")" = 1 ]
  # control: an exclusion naming another key leaves Issue-12 to be added once
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-PROJ-13 -->' > "$TMPDEV/WBS.md"
  _update
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '{issue: Issue-12, est: ?w' "$TMPDEV/WBS.md")" = 1 ]
}

@test "an excluded issue that has a leaf is still reconciled (#780)" {
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-12 -->' \
    '- [ ] Twelve {issue: Issue-12, est: 1w}' > "$TMPDEV/WBS.md"
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-12 -->' \
    '- [x] Twelve {issue: Issue-12, est: 1w, status_src: tracker}' > "$TMPDEV/expected"
  _list acme/testproj $'12\tdone'
  _active Issue-12
  _update_diff
  [ "$(grep -c 'not added' <<<"$output")" = 0 ]
}

# --- #803: wbs update orders by default ---------------------------------------

# _wbs_cfg <key> <raw-value>: append one [project.testproj.wbs] key.
_wbs_cfg() {
  local cfg="$HOME/.claude/devagent/config.toml"
  if ! grep -qxF '[project.testproj.wbs]' "$cfg"; then
    printf '\n[project.testproj.wbs]\n' >> "$cfg"
  fi
  printf '%s = %s\n' "$1" "$2" >> "$cfg"
}

# The set A (depends on C), B, C; the stub closes Issue-2 (B).
_order_leg() {
  printf '%s\n' '# testproj WBS' '' '- [ ] E' \
    '  - [ ] A {issue: Issue-1, depends_on: Issue-3}' \
    '  - [ ] B {issue: Issue-2}' \
    '  - [ ] C {issue: Issue-3}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen' $'2\tdone' $'3\topen'
}

# _order_expect <line>...: the expected WBS.md, with the leaf lines given.
_order_expect() {
  printf '%s\n' '# testproj WBS' '' '- [ ] E' "$@" > "$TMPDEV/expected"
}

A_LINE='  - [ ] A {issue: Issue-1, depends_on: Issue-3}'
B_DONE='  - [x] B {issue: Issue-2, status_src: tracker}'
C_LINE='  - [ ] C {issue: Issue-3}'

@test "cleanup's call: one write flips the glyph and sorts the set; a repeat is a no-op (#803)" {
  _order_leg
  _order_expect "$C_LINE" "$B_DONE" "$A_LINE"
  run "$REPO/scripts/wbs-update.sh" --if-exists testproj
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
  run "$REPO/scripts/wbs-update.sh" --if-exists testproj
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
}

@test "order_on_update = false keeps the order and still updates glyphs (#803)" {
  _order_leg
  _wbs_cfg order_on_update false
  _order_expect "$A_LINE" "$B_DONE" "$C_LINE"
  _update_diff
}

@test "an invalid order_on_update or completed_last warns, writes the glyph, exits 0 (#803)" {
  local cfg="$HOME/.claude/devagent/config.toml"
  cp "$cfg" "$cfg.base"
  _order_expect "$A_LINE" "$B_DONE" "$C_LINE"

  _order_leg
  _wbs_cfg order_on_update '"maybe"'
  _update_diff
  run grep -cxF "wbs update: [project.testproj.wbs] order_on_update must be true or false, got 'maybe'; ordering skipped" <<<"$output"
  [ "$output" = "1" ]

  cp "$cfg.base" "$cfg"
  _order_leg
  _wbs_cfg completed_last 1
  _update_diff
  run grep -cxF "wbs update: [project.testproj.wbs] completed_last must be true or false, got '1'; ordering skipped" <<<"$output"
  [ "$output" = "1" ]
}

@test "completed_last = true moves a leaf closed in this run after its open siblings (#803)" {
  _order_leg
  _wbs_cfg completed_last true
  _order_expect "$C_LINE" "$A_LINE" "$B_DONE"
  _update_diff
}

@test "an aborted tracker lookup still orders (#803)" {
  _order_leg
  _list_fail acme/testproj 1 'HTTP 401'
  # no glyph changes; C (one dependent) leads, then A and B by position
  _order_expect "$C_LINE" "$A_LINE" '  - [ ] B {issue: Issue-2}'
  _update_diff
  [[ "$output" == *"wbs update: WARNING: tracker lookup failed for github acme/testproj"* ]]
}

@test "an unknown [project.p.wbs] key warns once (#803)" {
  _order_leg
  _wbs_cfg order_on_updates false
  _order_expect "$C_LINE" "$B_DONE" "$A_LINE"
  _update_diff
  run grep -cxF "wbs update: [project.testproj.wbs] unknown key 'order_on_updates' ignored" <<<"$output"
  [ "$output" = "1" ]
}
