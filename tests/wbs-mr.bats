#!/usr/bin/env bats
#
# #704: `wbs update`'s MR phase. After #703's tracker phase, issue leaves the
# tracker leaves open take their linked-MR state from the code backend's
# `issue-mrs` verb. Issue and code backends are the stub in
# tests/fixtures/wbs-tracker (see its header; `issue-mrs.<backend>.<repo>`
# files) except in the "real ... code backend" tests, which run
# scripts/code/{github,gitlab}.sh over the recorded fixtures. gh/glab/curl
# shims on PATH log to network.log, which teardown asserts absent.

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
  _config github acme/testproj yes github

  export TMPROOT
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  export DEVAGENT_CODE_BACKEND_DIR="$TMPROOT/code-backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
  wbs_mr_install_stub "$DEVAGENT_CODE_BACKEND_DIR"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
  unset DEVAGENT_WBS_OFFLINE DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_GITHUB_LABEL_IN_PROGRESS \
    DEVAGENT_GITLAB_LABELS_IN_PROGRESS DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS DEVAGENT_PROJECT \
    GH_STUB_GRAPHQL_DIR GH_STUB_ARGS_LOG
}

teardown() {
  if declare -F fixture_stop >/dev/null 2>&1; then fixture_stop; fi
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

# _config <origin-backend> <origin-repo> <fork: yes|no> <code-backend|none>
_config() {
  local ob="$1" orepo="$2" fork="$3" cb="$4"
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' '' \
      '[project.testproj]' "source_dir = \"$TMPROOT/src\"" "devdoc_dir = \"$TMPDEV\"" \
      '' '[project.testproj.issue_source]' "backend = \"$ob\"" \
      "repo = \"$orepo\"" 'dir_prefix = "Issue-"'
    if [ "$fork" = yes ]; then
      printf '%s\n' '' '[project.testproj.issue_source_fork]' "backend = \"$ob\"" \
        'repo = "me/testproj-fork"' 'dir_prefix = "Issue-Fork-"'
    fi
    if [ "$cb" != none ]; then
      printf '%s\n' '' '[project.testproj.code_source]' "backend = \"$cb\"" \
        "upstream = \"$orepo\"" 'fork = "me/testproj-fork"'
    fi
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

# _mr <repo> <line>...: the stub github issue-mrs output for <repo>.
_mr() {
  local repo="$1"; shift
  printf '%s\n' "$@" > "$TMPROOT/issue-mrs.github.${repo//\//_}"
}

# _mr_fail <repo> <rc> <stderr>: the stub's issue-mrs for <repo> fails.
_mr_fail() {
  local f="$TMPROOT/issue-mrs.github.${1//\//_}"
  [ -f "$f" ] || : > "$f"
  printf '%s\n' "$2" > "$f.rc"
  printf '%s\n' "$3" > "$f.err"
}

# _mrl <id> <ref> <state> [merged]: one `mr` line.
_mrl() {
  printf 'mr\t%s\t%s\t%s\t2026-07-01T00:00:00Z\t%s' "$1" "$2" "$3" "${4:--}"
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

# _calls: the number of issue-mrs calls in the stub log.
_calls() {
  grep -c '^\[issue-mrs\]' "$TMPROOT/backend.log" 2>/dev/null || true
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

WARN_TAIL="no mr: value or MR glyph changed (they may be stale)."

@test "open, draft and merged MR states set [~], status_src: mr and mr: (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Open {issue: Issue-1, est: 1w}
- [x] Draft {issue: Issue-2, est: 1w, status_src: checklist}
- [ ] Merged {issue: Issue-3, est: 1w}
EOF
  _cl Issue-2 "done"
  _list acme/testproj $'1\topen' $'2\topen' $'3\tin_progress'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" \
    $'issue\t2\tdraft' "$(_mrl 2 acme/testproj#12 draft)" \
    $'issue\t3\tmerged' "$(_mrl 3 acme/testproj#13 merged 2026-07-02T00:00:00Z)"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] Open {issue: Issue-1, est: 1w, status_src: mr, mr: open}
- [~] Draft {issue: Issue-2, est: 1w, status_src: mr, mr: draft}
- [~] Merged {issue: Issue-3, est: 1w, status_src: mr, mr: merged}
EOF
  _update_diff
  grep -qxF '[issue-mrs] [acme/testproj] [1] [2] [3] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  [ "$(_calls)" -eq 1 ]
}

@test "hand-set [P] [!] [?] keep their glyph; only mr: is written (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [P] Parked {issue: Issue-1, est: 1w}
- [!] Stuck {issue: Issue-2, est: 1w}
- [?] Blocked {issue: Issue-3, est: 1w, status_src: checklist}
EOF
  _list acme/testproj $'1\topen' $'2\tin_progress' $'3\topen'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" \
    $'issue\t2\tdraft' "$(_mrl 2 acme/testproj#12 draft)" \
    $'issue\t3\tmerged' "$(_mrl 3 acme/testproj#13 merged 2026-07-02T00:00:00Z)"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [P] Parked {issue: Issue-1, est: 1w, mr: open}
- [!] Stuck {issue: Issue-2, est: 1w, mr: draft}
- [?] Blocked {issue: Issue-3, est: 1w, status_src: checklist, mr: merged}
EOF
  _update_diff
}

@test "MR state none drops mr: and takes #703's result for an MR-set leaf (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Checklist {issue: Issue-1, est: 1w, status_src: mr, mr: open}
- [~] Abandoned {issue: Issue-2, est: 1w, status_src: mr, mr: open}
- [P] Parked {issue: Issue-3, est: 1w, status_src: mr, mr: merged}
- [~] Not MR-set {issue: Issue-4, est: 1w, status_src: checklist, mr: draft}
EOF
  _cl Issue-1 progress
  _cl Issue-4 progress
  _list acme/testproj $'1\topen' $'2\topen' $'3\topen' $'4\topen'
  _mr acme/testproj $'issue\t1\tnone' $'issue\t2\tnone' "$(_mrl 2 acme/testproj#12 closed)" \
    $'issue\t3\tnone' $'issue\t4\tnone'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] Checklist {issue: Issue-1, est: 1w, status_src: checklist}
- [ ] Abandoned {issue: Issue-2, est: 1w}
- [P] Parked {issue: Issue-3, est: 1w, status_src: mr}
- [~] Not MR-set {issue: Issue-4, est: 1w, status_src: checklist}
EOF
  _update_diff
}

@test "an abandoned-MR leaf is a fixed point: a second run makes no diff (#704)" {
  printf '%s\n' '# testproj WBS' '' '- [~] A {issue: Issue-2, est: 1w, status_src: mr, mr: open}' \
    > "$TMPDEV/WBS.md"
  _list acme/testproj $'2\topen'
  _mr acme/testproj $'issue\t2\tnone' "$(_mrl 2 acme/testproj#12 closed)"
  printf '%s\n' '# testproj WBS' '' '- [ ] A {issue: Issue-2, est: 1w}' > "$TMPDEV/expected"
  _update_diff
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.run1"
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/WBS.run1" "$TMPDEV/WBS.md"
}

@test "no code_source.backend: closed leaves drop mr:, open MR leaves follow #703, one note (#704)" {
  _config github acme/testproj no none
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Closed {issue: Issue-1, est: 1w, status_src: mr, mr: merged}
- [~] Open {issue: Issue-2, est: 1w, status_src: mr, mr: open}
EOF
  _cl Issue-2 pending
  _list acme/testproj $'1\tdone' $'2\topen'
  _mr acme/testproj $'issue\t2\topen' "$(_mrl 2 acme/testproj#12 open)"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Closed {issue: Issue-1, est: 1w, status_src: tracker}
- [ ] Open {issue: Issue-2, est: 1w, status_src: checklist, mr: open}
EOF
  _update_diff
  run grep -c 'wbs update: no code_source.backend; MR state not read' <<< "$output"
  [ "$output" = 1 ]
  [ "$(_calls)" -eq 0 ]
  # no leaf carries MR meta any more after a clean tree: no note
  printf '%s\n' '# testproj WBS' '' '- [ ] Plain {issue: Issue-2, est: 1w}' > "$TMPDEV/WBS.md"
  _update
  [ "$status" -eq 0 ]
  [[ "$output" != *"MR state not read"* ]]
}

@test "closed issues drop mr: and send no ids (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Done {issue: Issue-1, est: 1w, status_src: mr, mr: merged}
- [~] Not planned {issue: Issue-2, est: 1w, mr: open}
EOF
  _list acme/testproj $'1\tdone' $'2\tnot_planned'
  _mr acme/testproj $'issue\t1\tmerged'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Done {issue: Issue-1, est: 1w, status_src: tracker}
- [-] Not planned {issue: Issue-2, est: 1w, status_src: tracker}
EOF
  _update_diff
  [ "$(_calls)" -eq 0 ]
}

@test "tracker-missing leaves are skipped and never sent (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Listed {issue: Issue-1, est: 1w}
- [~] Missing {issue: Issue-9, est: 1w, status_src: mr, mr: open}
EOF
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] Listed {issue: Issue-1, est: 1w, status_src: mr, mr: open}
- [~] Missing {issue: Issue-9, est: 1w, status_src: mr, mr: open}
EOF
  _update_diff
  grep -qxF '[issue-mrs] [acme/testproj] [1] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
}

@test "an MR-lookup missing id changes only that leaf's report line (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] One {issue: Issue-1, est: 1w}
- [ ] Two {issue: Issue-2, est: 1w, mr: draft}
EOF
  _list acme/testproj $'1\topen' $'2\topen'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" $'issue\t2\tmissing'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] One {issue: Issue-1, est: 1w, status_src: mr, mr: open}
- [ ] Two {issue: Issue-2, est: 1w, mr: draft}
EOF
  _update_diff
  run grep -c 'wbs update: Issue-2 not found on github acme/testproj (MR lookup); leaf unchanged' <<< "$output"
  [ "$output" = 1 ]
}

@test "a failed MR lookup leaves the tracker-phase result byte-identical, one WARNING, exit 0 (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Closed {issue: Issue-1, est: 1w, status_src: mr, mr: merged}
- [~] Held {issue: Issue-2, est: 1w, status_src: mr, mr: open}
- [ ] Plain {issue: Issue-3, est: 1w}
EOF
  _cl Issue-2 pending
  _list acme/testproj $'1\tdone' $'2\topen' $'3\topen'
  _mr acme/testproj $'issue\t2\tnone' $'issue\t3\topen' "$(_mrl 3 acme/testproj#13 open)"
  _mr_fail acme/testproj 1 'gh: connection reset'
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Closed {issue: Issue-1, est: 1w, status_src: tracker, mr: merged}
- [~] Held {issue: Issue-2, est: 1w, status_src: mr, mr: open}
- [ ] Plain {issue: Issue-3, est: 1w}
EOF
  _update
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
  run grep -c 'WARNING' <<< "$output"
  [ "$output" = 1 ]
  _update
  [[ "$output" == *"wbs update: WARNING: MR lookup failed for github acme/testproj (exit 1: gh: connection reset); $WARN_TAIL"* ]]
}

@test "malformed issue-mrs output aborts the MR phase (#704)" {
  local bad
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' \
    '- [ ] Two {issue: Issue-2, est: 1w}' > "$TMPDEV/WBS.input"
  _list acme/testproj $'1\topen' $'2\topen'
  for bad in missing-id bad-state mismatch; do
    cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
    case "$bad" in
      missing-id) _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" ;;
      bad-state)  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" $'issue\t2\tweird' ;;
      mismatch)   _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 merged 2026-07-02T00:00:00Z)" $'issue\t2\tnone' ;;
    esac
    _update
    [ "$status" -eq 0 ]
    cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
    run grep -c 'WARNING: MR lookup failed for github acme/testproj' <<< "$output"
    [ "$output" = 1 ]
  done
}

@test "the first failing source stops the phase: no call to the next source (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Origin {issue: Issue-1, est: 1w}
- [ ] Fork {issue: Issue-Fork-1, est: 1w}
EOF
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  _list acme/testproj $'1\topen'
  _list me/testproj-fork $'1\topen'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)"
  _mr_fail me/testproj-fork 3 'HTTP 401'
  _update
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
  grep -qxF '[issue-mrs] [me/testproj-fork] [1] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  [[ "$output" == *"MR lookup failed for github me/testproj-fork (exit 3: HTTP 401)"* ]]
}

@test "--offline and DEVAGENT_WBS_OFFLINE=1 make no issue-mrs call and hold MR-set glyphs (#704)" {
  printf '%s\n' '# testproj WBS' '' '- [~] A {issue: Issue-1, est: 1w, status_src: mr, mr: open}' \
    > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/expected"
  _cl Issue-1 pending
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\tnone'
  _update_diff --offline
  [ ! -e "$TMPROOT/backend.log" ]
  export DEVAGENT_WBS_OFFLINE=1
  _update_diff
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "a tracker-phase abort skips the MR phase (#704)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] A {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/expected"
  _list acme/testproj $'1\topen'
  printf '1\n' > "$TMPROOT/state-list.github.acme_testproj.rc"
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)"
  _update_diff
  [ "$(_calls)" -eq 0 ]
  [[ "$output" == *"WARNING: tracker lookup failed"* ]]
  [[ "$output" != *"MR lookup failed"* ]]
}

@test "fork and origin sources each get one call with their own repo (#704)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Origin five {issue: Issue-5, est: 1w}
- [ ] Fork five {issue: Issue-Fork-5, est: 1w}
EOF
  _list acme/testproj $'5\topen'
  _list me/testproj-fork $'5\topen'
  _mr acme/testproj $'issue\t5\tnone'
  _mr me/testproj-fork $'issue\t5\topen' "$(_mrl 5 me/testproj-fork#3 open)"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [ ] Origin five {issue: Issue-5, est: 1w}
- [~] Fork five {issue: Issue-Fork-5, est: 1w, status_src: mr, mr: open}
EOF
  _update_diff
  [ "$(_calls)" -eq 2 ]
  grep -qxF '[issue-mrs] [me/testproj-fork] [5] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  grep -qxF '[issue-mrs] [acme/testproj] [5] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
}

@test "a code backend without issue-mrs, or without its CLI, is no lookup: one note, closed leaves still drop mr: (#704)" {
  local stripped
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Closed {issue: Issue-1, est: 1w, status_src: mr, mr: merged}
- [~] Held {issue: Issue-2, est: 1w, status_src: mr, mr: open}
EOF
  _cl Issue-2 pending
  _list acme/testproj $'1\tdone' $'2\topen'
  # no issue-mrs file: the stub exits 78
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [x] Closed {issue: Issue-1, est: 1w, status_src: tracker}
- [~] Held {issue: Issue-2, est: 1w, status_src: mr, mr: open}
EOF
  _update_diff
  run grep -c 'wbs update: github has no issue-mrs (exit 78); MR state not read' <<< "$output"
  [ "$output" = 1 ]
  [ "$(_calls)" -eq 1 ]
  _update
  [[ "$output" != *WARNING* ]]
  # a backend older than the verb exits 2 (unknown verb): the same note
  _mr_fail acme/testproj 2 ''
  _update
  [ "$status" -eq 0 ]
  [[ "$output" != *WARNING* ]]
  run grep -c 'wbs update: github has no issue-mrs (exit 2); MR state not read' <<< "$output"
  [ "$output" = 1 ]
  rm -f "$TMPROOT"/issue-mrs.github.acme_testproj*
  # no code backend script at all
  rm -f "$DEVAGENT_CODE_BACKEND_DIR/github.sh"
  _update
  [ "$status" -eq 0 ]
  run grep -c 'wbs update: github has no issue-mrs (no script); MR state not read' <<< "$output"
  [ "$output" = 1 ]
  # no gh: the code backend's CLI probe fails (the tracker's too)
  wbs_mr_install_stub "$DEVAGENT_CODE_BACKEND_DIR"
  stripped="$(_path_without gh)"
  (PATH="$stripped"; command -v python3 >/dev/null) || skip "gh shares a PATH dir with python3 here"
  PATH="$stripped"
  export PATH
  _update
  [ "$status" -eq 0 ]
  run grep -c 'wbs update: github has no issue-mrs (gh not on PATH); MR state not read' <<< "$output"
  [ "$output" = 1 ]
  [[ "$output" != *WARNING* ]]
}

@test "a code backend unlike the source's backend is skipped (#704)" {
  _config github acme/testproj no gitlab
  printf '%s\n' '# testproj WBS' '' '- [ ] A {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/expected"
  _list acme/testproj $'1\topen'
  printf '%s\n' $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" > "$TMPROOT/issue-mrs.gitlab"
  _update_diff
  [ "$(_calls)" -eq 0 ]
  [[ "$output" != *WARNING* ]]
}

@test "only glyph, status_src and mr bytes change; a second run is a no-op (#704)" {
  local kind
  printf '%s\n' '<!-- note -->' '# testproj WBS' '' 'Prose that must survive.' '' \
    '- [ ] Compact {issue: Issue-1,est:1w}' '  Note under the leaf.' \
    '- [~] Gone {issue: Issue-2,est:1w,status_src:mr,mr:open}' \
    '- [~] Merged {issue: Issue-3, est: 1w, mr: draft, owner: @me}' > "$TMPDEV/WBS.lf"
  printf '%s\n' '<!-- note -->' '# testproj WBS' '' 'Prose that must survive.' '' \
    '- [~] Compact {issue: Issue-1,est:1w, status_src: mr, mr: open}' '  Note under the leaf.' \
    '- [ ] Gone {issue: Issue-2,est:1w}' \
    '- [~] Merged {issue: Issue-3, est: 1w, mr: merged, owner: @me, status_src: mr}' > "$TMPDEV/expected.lf"
  _list acme/testproj $'1\topen' $'2\topen' $'3\topen'
  _mr acme/testproj $'issue\t1\topen' "$(_mrl 1 acme/testproj#11 open)" $'issue\t2\tnone' \
    $'issue\t3\tmerged' "$(_mrl 3 acme/testproj#13 merged 2026-07-02T00:00:00Z)"
  for kind in lf crlf; do
    python3 "$REPO/tests/helpers/wbs_bytes.py" variant "$TMPDEV/WBS.lf" "$kind" "$TMPDEV/WBS.md"
    python3 "$REPO/tests/helpers/wbs_bytes.py" variant "$TMPDEV/expected.lf" "$kind" "$TMPDEV/expected"
    _update
    [ "$status" -eq 0 ]
    cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
    _update
    [ "$status" -eq 0 ]
    cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
  done
}

@test "the auto-added active issue takes its MR state (#704)" {
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _active Issue-7
  _list acme/testproj $'1\topen' $'7\topen'
  _mr acme/testproj $'issue\t1\tnone' $'issue\t7\tdraft' "$(_mrl 7 acme/testproj#17 draft)"
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' \
    '- [ ] Unassigned' '  - [~] Issue-7 {issue: Issue-7, est: ?w, status_src: mr, mr: draft}' \
    > "$TMPDEV/expected"
  _update_diff
  grep -qxF '[issue-mrs] [acme/testproj] [1] [7] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
}

@test "real github code backend: a merged PR into dev/all-prs makes the open issue [~] mr: merged (#704)" {
  _config github acme/testproj no github
  unset DEVAGENT_CODE_BACKEND_DIR
  mkdir -p "$TMPROOT/ghbin" "$TMPROOT/gql"
  cp "$REPO/tests/fixtures/gh-stub" "$TMPROOT/ghbin/gh"
  chmod +x "$TMPROOT/ghbin/gh"
  export PATH="$TMPROOT/ghbin:$PATH"   # the shim dir stays: a stray curl is caught
  export GH_STUB_GRAPHQL_DIR="$TMPROOT/gql"
  cp "$REPO/tests/fixtures/code-github/issue-mrs-links.json" "$TMPROOT/gql/1.json"
  printf '%s\n' '# testproj WBS' '' '- [ ] Stacked {issue: Issue-6, est: 1w}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'6\topen'
  printf '%s\n' '# testproj WBS' '' \
    '- [~] Stacked {issue: Issue-6, est: 1w, status_src: mr, mr: merged}' > "$TMPDEV/expected"
  _update_diff
  [ "$(cat "$TMPROOT/gql/count")" -eq 1 ]
}

@test "real gitlab code backend through the fixture server (#704)" {
  _config gitlab foo/bar no gitlab
  unset DEVAGENT_CODE_BACKEND_DIR
  PATH="$(_path_without)"
  export PATH
  fixture_start "$REPO/tests/fixtures/gitlab"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4" GITLAB_TOKEN=dummy-token
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Six {issue: Issue-6, est: 1w}
- [ ] Ten {issue: Issue-10, est: 1w}
EOF
  printf '%s\n' $'6\topen' $'10\topen' > "$TMPROOT/state-list.gitlab.foo_bar"
  cat > "$TMPDEV/expected" <<'EOF'
# testproj WBS

- [~] Six {issue: Issue-6, est: 1w, status_src: mr, mr: merged}
- [~] Ten {issue: Issue-10, est: 1w, status_src: mr, mr: open}
EOF
  _update_diff
  [ "$(grep -c '/related_merge_requests' "$FIXTURE_REQUEST_LOG")" -eq 2 ]
  # a full page of related MRs aborts the phase and names the cap
  printf '%s\n' '# testproj WBS' '' '- [ ] Twelve {issue: Issue-12, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/expected"
  printf '%s\n' $'12\topen' > "$TMPROOT/state-list.gitlab.foo_bar"
  _update_diff
  [[ "$output" == *"WARNING: MR lookup failed for gitlab foo/bar (exit 5: gitlab.sh: issue-mrs: issue 12 has 100+ related MRs (cap)); $WARN_TAIL"* ]]
}

@test "network control: with DEVAGENT_CODE_BACKEND_DIR unset, the real code backend reaches the gh shim (#704 control)" {
  _config github acme/testproj no github
  unset DEVAGENT_CODE_BACKEND_DIR
  printf '%s\n' '# testproj WBS' '' '- [ ] A {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen'
  _update
  [ "$status" -eq 0 ]
  [ -e "$TMPROOT/network.log" ]
  grep -q '^gh api graphql' "$TMPROOT/network.log"
  [[ "$output" == *"WARNING: MR lookup failed for github acme/testproj"* ]]
  rm -f "$TMPROOT/network.log"
}

@test "keys pass writes nothing: the WBS mtime and bytes are unchanged when the MR call fails (#704)" {
  local before after
  printf '%s\n' '# testproj WBS' '' '- [ ] A {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
  touch -d '2020-01-01 00:00:00' "$TMPDEV/WBS.md"
  before="$(stat -c %Y "$TMPDEV/WBS.md")"
  _list acme/testproj $'1\topen'
  _mr_fail acme/testproj 1 'boom'
  _update
  [ "$status" -eq 0 ]
  after="$(stat -c %Y "$TMPDEV/WBS.md")"
  [ "$before" = "$after" ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  [ "$(_calls)" -eq 1 ]
}

# --- #780: an active issue a wbs-exclude line names is not auto-added ---------

# _not_added <id> <line>: the one line update prints instead of adding <id>.
_not_added() {
  printf 'wbs update: %s is listed in a wbs-exclude line (line %s); not added. Remove it from every wbs-exclude line that lists it to track it in the WBS.\n' "$1" "$2"
}

@test "an excluded pinned active issue is not added; one not-added line, bytes unchanged (#780)" {
  local out
  # Issue-12 shares line 3 with another id and is named again on line 5;
  # the first line is the one reported
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-3, Issue-12 -->' \
    '- [ ] One {issue: Issue-1, est: 1w}' '<!-- wbs-exclude: Issue-12 -->' > "$TMPDEV/WBS.input"
  cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\tnone'
  DEVAGENT_ACTIVE_ISSUE=Issue-12 _update
  out="$output"
  [ "$status" -eq 0 ] || { echo "$out"; false; }
  [ "$(grep -cxF "$(_not_added Issue-12 3)" <<<"$out")" = 1 ]
  [ "$(grep -c 'not added' <<<"$out")" = 1 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  # the keys pass ran (one issue-mrs call), so say() kept it to one line (U1)
  [ "$(_calls)" -eq 1 ]
  [ "$(grep -c Unassigned "$TMPDEV/WBS.md")" = 0 ]
  # control: without the exclusion line, Issue-12 is added
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  DEVAGENT_ACTIVE_ISSUE=Issue-12 _update
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '{issue: Issue-12, est: ?w' "$TMPDEV/WBS.md")" = 1 ]
}

@test "update prints no exclusion warning: malformed line, unknown prefix (#780)" {
  local out
  printf '%s\n' '# testproj WBS' '' '<!-- WBS-Exclude: Issue-5 -->' \
    '<!-- wbs-exclude: Task-9 -->' '<!-- wbs-exclude: Issue-12 -->' \
    '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\tnone'
  DEVAGENT_ACTIVE_ISSUE=Issue-12 _update
  out="$output"
  [ "$status" -eq 0 ] || { echo "$out"; false; }
  [ "$(grep -cxF "$(_not_added Issue-12 5)" <<<"$out")" = 1 ]
  [ "$(grep -c 'not an exclusion line' <<<"$out")" = 0 ]
  [ "$(grep -c 'is not an issue id' <<<"$out")" = 0 ]
  [ "$(grep -vxF "$(_not_added Issue-12 5)" <<<"$out" | grep -ci 'wbs-exclude')" = 0 ]
  # positive control: the file really carries a warning that update suppressed
  [ "$(python3 "$REPO/scripts/lib/wbs-parser.py" parse "$TMPDEV/WBS.md" \
        | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["exclusion_warnings"]))')" = 1 ]
}

@test "an exclusion id the codec cannot read does not exclude (#780)" {
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: 12 -->' \
    '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\tnone'
  DEVAGENT_ACTIVE_ISSUE=Issue-12 _update
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '{issue: Issue-12, est: ?w' "$TMPDEV/WBS.md")" = 1 ]
  [ "$(grep -c 'not added' <<<"$output")" = 0 ]
}

@test "the shared active_issue slot, no pin: same result (#780)" {
  local out
  printf '%s\n' '# testproj WBS' '' '<!-- wbs-exclude: Issue-12 -->' \
    '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.input"
  cp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  _list acme/testproj $'1\topen'
  _mr acme/testproj $'issue\t1\tnone'
  _active Issue-12
  # cleanup's path: the shared slot, no session pin, --offline
  run env -u DEVAGENT_ACTIVE_ISSUE bash "$REPO/scripts/wbs.sh" update testproj --offline
  out="$output"
  [ "$status" -eq 0 ] || { echo "$out"; false; }
  [ "$(grep -cxF "$(_not_added Issue-12 3)" <<<"$out")" = 1 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  # offline: no issue-mrs call (the stub log is absent or holds none)
  [ ! -e "$TMPROOT/backend.log" ] || [ "$(_calls)" -eq 0 ]
  [ "$(grep -c Unassigned "$TMPDEV/WBS.md")" = 0 ]
  # control: without the exclusion line, the slot's issue is added
  printf '%s\n' '# testproj WBS' '' '- [ ] One {issue: Issue-1, est: 1w}' > "$TMPDEV/WBS.md"
  run env -u DEVAGENT_ACTIVE_ISSUE bash "$REPO/scripts/wbs.sh" update testproj --offline
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '{issue: Issue-12, est: ?w' "$TMPDEV/WBS.md")" = 1 ]
}
