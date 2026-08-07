#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Two projects so single-project shortcut doesn't kick in unexpectedly.
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/volk"

[project.gnuradio]
source_dir = "$BATS_TEST_TMPDIR/gnuradio"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc/gnuradio"
EOF
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk" "$BATS_TEST_TMPDIR/devdoc/gnuradio"
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/active.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "active_set/get_project round-trip writes mode 600" {
  active_set_project volk
  [ "$(active_get_project)" = "volk" ]
  local mode
  mode="$(stat -c '%a' "$(active_pointer_path)")"
  [ "$mode" = "600" ]
}

# --- #328: atomic pointer write (tmp+rename, lock, mode-on-create) -----------

@test "active_set_project writes atomically — pointer inode changes across a write (#328)" {
  # tmp+rename ⇒ a fresh inode each write; the old in-place `printf >` kept it
  # (the O_TRUNC window a concurrent reader could catch empty). Deterministic
  # born-red: ino1 == ino2 before the fix.
  active_set_project volk
  local ino1 ino2
  ino1="$(stat -c '%i' "$(active_pointer_path)")"
  active_set_project volk
  ino2="$(stat -c '%i' "$(active_pointer_path)")"
  [ "$ino1" != "$ino2" ]
}

@test "active_set_project creates the pointer 0600 with no umask window (#328)" {
  # The atomic path chmods the tmp BEFORE the rename, so the pointer is 0600 the
  # instant it exists — closing the window the old post-hoc chmod left open.
  ( umask 022; active_set_project volk )
  [ "$(stat -c '%a' "$(active_pointer_path)")" = "600" ]
}

@test "active_set_project: concurrent writers never expose a partial pointer (#328)" {
  # Belt-and-braces hammer (racy by nature): while writers churn, a reader must
  # always see a whole, valid project name — never empty/partial.
  active_set_project volk
  for _ in $(seq 1 20); do active_set_project volk & active_set_project gnuradio & done
  for _ in $(seq 1 40); do
    local v; v="$(active_get_project)"
    [ "$v" = "volk" ] || [ "$v" = "gnuradio" ]
  done
  wait
}

@test "active_resolve_project: explicit arg wins" {
  active_set_project volk
  export DEVAGENT_ACTIVE_PROJECT=gnuradio
  [ "$(active_resolve_project gnuradio)" = "gnuradio" ]
  [ "$(active_resolve_project volk)" = "volk" ]
}

@test "active_resolve_project: env var wins over global pointer" {
  active_set_project volk
  DEVAGENT_ACTIVE_PROJECT=gnuradio run active_resolve_project
  [ "$output" = "gnuradio" ]
}

@test "active_resolve_project: global pointer wins when no arg/env" {
  active_set_project gnuradio
  run active_resolve_project
  [ "$output" = "gnuradio" ]
}

@test "active_resolve_project: dies when no pointer and 2+ projects" {
  run active_resolve_project
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 projects"* ]]
}

@test "active_resolve_issue: arg wins" {
  state_init volk
  state_set volk active_issue Issue-5
  [ "$(active_resolve_issue volk Issue-99)" = "Issue-99" ]
}

@test "active_resolve_issue: per-project state wins when no arg/env" {
  state_init volk
  state_set volk active_issue Issue-42
  [ "$(active_resolve_issue volk)" = "Issue-42" ]
}

@test "active_resolve_issue: env var wins over per-project state" {
  state_init volk
  state_set volk active_issue Issue-42
  DEVAGENT_ACTIVE_ISSUE=Issue-99 run active_resolve_issue volk
  [ "$output" = "Issue-99" ]
}

@test "active_resolve_issue: scans devdoc when state has no active_issue" {
  # Two issue dirs, the older one complete, the newer one incomplete.
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1" \
           "$BATS_TEST_TMPDIR/devdoc/volk/Issue-2"
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1/checklist.md" <<'EOF'
- [x] 0. pull
- [x] 2. draft
EOF
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-2/checklist.md" <<'EOF'
- [x] 0. pull
- [ ] 2. draft
EOF
  # Make Issue-2 newer.
  touch -d "1 minute ago" "$BATS_TEST_TMPDIR/devdoc/volk/Issue-1/checklist.md"
  state_init volk
  run active_resolve_issue volk
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-2" ]
}

@test "active_resolve_issue: returns most recently touched even with in-progress mark" {
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3"
  cat > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3/checklist.md" <<'EOF'
- [x] 0. pull
- [~] 2. draft
EOF
  state_init volk
  run active_resolve_issue volk
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-3" ]
}

# --- #282: source-aware resolution -----------------------------------------

@test "active_resolve_project_src reports source=arg (#282)" {
  unset DEVAGENT_ACTIVE_PROJECT
  active_resolve_project_src volk
  [ "$ACTIVE_RESOLVED_PROJECT" = "volk" ]
  [ "$ACTIVE_RESOLVED_FROM" = "arg" ]
}

@test "active_resolve_project_src reports source=env (#282)" {
  export DEVAGENT_ACTIVE_PROJECT=gnuradio
  active_resolve_project_src ""
  [ "$ACTIVE_RESOLVED_PROJECT" = "gnuradio" ]
  [ "$ACTIVE_RESOLVED_FROM" = "env" ]
}

@test "active_resolve_project_src reports source=pointer (#282)" {
  unset DEVAGENT_ACTIVE_PROJECT
  active_set_project gnuradio
  active_resolve_project_src ""
  [ "$ACTIVE_RESOLVED_PROJECT" = "gnuradio" ]
  [ "$ACTIVE_RESOLVED_FROM" = "pointer" ]
}

@test "active_resolve_project echo wrapper stays byte-compatible (#282)" {
  unset DEVAGENT_ACTIVE_PROJECT
  active_set_project volk
  [ "$(active_resolve_project)" = "volk" ]
  [ "$(active_resolve_project gnuradio)" = "gnuradio" ]
}

# ---- #240: active_resolve_issue_src + env-pin validation --------------------

@test "active_resolve_issue_src reports src=arg in the calling shell (#240)" {
  state_init volk
  active_resolve_issue_src volk Issue-9
  [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "arg" ]
  [ "$ACTIVE_RESOLVED_ISSUE" = "Issue-9" ]
}

@test "active_resolve_issue_src reports src=env under a pin (#240)" {
  state_init volk
  DEVAGENT_ACTIVE_ISSUE=Issue-7 active_resolve_issue_src volk
  [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "env" ]
  [ "$ACTIVE_RESOLVED_ISSUE" = "Issue-7" ]
}

@test "active_resolve_issue_src reports src=state from the shared pointer (#240)" {
  state_init volk
  state_set volk active_issue Issue-40
  active_resolve_issue_src volk
  [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "state" ]
  [ "$ACTIVE_RESOLVED_ISSUE" = "Issue-40" ]
}

@test "env pin with an invalid id shape dies before any state touch (#240)" {
  # ']'/' ' corrupt the state file on first table write; '#' bricks the
  # comment-guard — empirically confirmed at plan time. Resolver = choke point.
  state_init volk
  DEVAGENT_ACTIVE_ISSUE='Issue 2]' run active_resolve_issue_src volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVAGENT_ACTIVE_ISSUE"* ]]
}

@test "env pin with a dotted id dies — dots nest TOML tables (#240)" {
  state_init volk
  DEVAGENT_ACTIVE_ISSUE='Issue.2' run active_resolve_issue_src volk
  [ "$status" -ne 0 ]
}

@test "active_resolve_issue echo wrapper honors the pin unchanged (#240 regression)" {
  state_init volk
  DEVAGENT_ACTIVE_ISSUE=Issue-7 run active_resolve_issue volk
  [ "$status" -eq 0 ]
  [ "$output" = "Issue-7" ]
}

# --- #571: active_tree_resolve / active_guard_tree ---------------------------
# The tree an EVIDENCE step must measure: state.worktree_path else source_dir
# (the commit.sh/ship.sh rule, hoisted). Setter-globals; never $( ... ).

@test "active_tree_resolve: no worktree_path -> source_dir, FROM=config (#571)" {
  type active_tree_resolve >/dev/null   # missing fn must redden, never 127-pass (#572)
  mkdir -p "$BATS_TEST_TMPDIR/volk"
  state_init volk
  active_tree_resolve volk
  [ "$ACTIVE_TREE_DIR" -ef "$BATS_TEST_TMPDIR/volk" ]
  [ "$ACTIVE_TREE_FROM" = "config" ]
}

@test "active_tree_resolve: recorded LIVE worktree_path wins, FROM=state (#571)" {
  type active_tree_resolve >/dev/null
  local wt="$BATS_TEST_TMPDIR/wt-volk"
  mkdir -p "$wt"
  ( cd "$wt" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name T \
      && git commit -q --allow-empty -m x )
  state_init volk
  state_set volk worktree_path "$wt"
  active_tree_resolve volk
  [ "$ACTIVE_TREE_DIR" = "$wt" ]
  [ "$ACTIVE_TREE_FROM" = "state" ]
}

@test "active_tree_resolve: recorded-but-DEAD worktree_path dies naming the path (#571)" {
  # fail-closed, mirroring ship.sh:94-98 — never silently measure source_dir instead
  type active_tree_resolve >/dev/null
  state_init volk
  state_set volk worktree_path "$BATS_TEST_TMPDIR/gone-wt"
  run active_tree_resolve volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"gone-wt"* ]]
}

@test "active_guard_tree: FROM=state is authoritative — no-op regardless of cwd (#571)" {
  # cwd = the CONFIGURED tree while ACTIVE_TREE_DIR = its linked worktree: the
  # exact shape clause 1 would refuse under FROM=config, so a pass here is
  # decided by the FROM=state early return, not by the clauses not matching.
  type active_guard_tree >/dev/null
  local src="$BATS_TEST_TMPDIR/volk" wt="$BATS_TEST_TMPDIR/wt-volk2"
  mkdir -p "$src"
  ( cd "$src" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name T \
      && git commit -q --allow-empty -m x && git branch -q wt2 \
      && git worktree add -q "$wt" wt2 )
  state_init volk
  state_set volk worktree_path "$wt"
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "state" ]
  cd "$src"
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
  [[ "$output" != *"TREE MISMATCH"* ]]
}

@test "active_guard_tree: unresolvable measured tree WARNS and proceeds (#571)" {
  # source_dir exists but is NOT a git repo: clause 1 cannot derive its common
  # dir, and the guard's documented undecidable branch warns rather than dying
  # or silently passing (review finding 5 — the one branch previously unpinned).
  type active_guard_tree >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/volk"          # exists, not a repo
  local other="$BATS_TEST_TMPDIR/other-repo"
  mkdir -p "$other"
  ( cd "$other" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name T \
      && git commit -q --allow-empty -m x )
  state_init volk
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "config" ]
  cd "$other"
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not compare"* ]]
}
