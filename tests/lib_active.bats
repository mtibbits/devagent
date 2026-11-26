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

@test "active_guard_tree: called before active_tree_resolve DIES (#571 redmr)" {
  # Programmer-error fail-closed: an unresolved guard must never be a silent
  # no-op that looks guarded (redmr MINOR — the one fail-open reachable by
  # code change rather than topology).
  type active_guard_tree >/dev/null
  unset ACTIVE_TREE_DIR ACTIVE_TREE_FROM
  run active_guard_tree lib-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"before active_tree_resolve"* ]]
}

# --- #879: worktree_path divergence ------------------------------------------
# A pinned/arg'd read of worktree_path returns the [context.<issue>] table value
# (#240: a table hit wins, even when empty). When that value is empty beside a
# non-empty top-level mirror for the SHARED active_issue, the read warns once on
# stderr; and the #571 guard's refusal names the home the read actually uses.

# T1 shape: shared slot Issue-7, table worktree_path "", top level non-empty.
# state_set runs LAST so the mirror ends up holding the non-empty value.
_wt879_fixture() {
  state_init volk
  state_set volk active_issue Issue-7
  state_issue_set_many volk Issue-7 str worktree_path ""
  state_set volk worktree_path "$BATS_TEST_TMPDIR/lab/wt"
}

# Counting stub: define AFTER the fixture writes, then reset the log. No exec —
# the function returns normally (as tests/state.bats does).
_wt879_stub() {
  _state_toml() {
    printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/toml-calls"
    python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" "$@"
  }
  : >"$BATS_TEST_TMPDIR/toml-calls"
}
_wt879_calls() { grep -c '' "$BATS_TEST_TMPDIR/toml-calls"; }

# The divergent read: rc 0, empty table value kept, exactly one warning line.
_wt879_assert_divergent_warn() {
  local rc="$1" out="$2" err="$3"
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  [ "$(grep -c '' "$err")" -eq 1 ]
  grep -qF '[context.Issue-7].worktree_path = ""' "$err"
  grep -qF 'lab/wt' "$err"
  grep -qF "$(state_path volk)" "$err"
  # AC2: names [context.<issue>] as THE home to fix, with the value to set
  grep -qF "set [context.Issue-7].worktree_path = \"$BATS_TEST_TMPDIR/lab/wt\"" "$err"
}

@test "state_ctx_get: divergent worktree_path (pinned) warns once and still returns the empty table value (#879)" {
  _wt879_fixture
  local out rc err="$BATS_TEST_TMPDIR/err"
  export DEVAGENT_ACTIVE_ISSUE=Issue-7
  { out="$(state_ctx_get volk worktree_path)"; rc=$?; } 2>"$err"
  _wt879_assert_divergent_warn "$rc" "$out" "$err"
}

@test "state_ctx_get: divergent worktree_path (arg'd) warns once and still returns the empty table value (#879)" {
  _wt879_fixture
  local out rc err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk worktree_path Issue-7)"; rc=$?; } 2>"$err"
  _wt879_assert_divergent_warn "$rc" "$out" "$err"
}

@test "state_ctx_get: table and top level agree — no warning (#879)" {
  state_init volk
  state_set volk active_issue Issue-7
  state_issue_set_many volk Issue-7 str worktree_path "$BATS_TEST_TMPDIR/lab/wt"
  local out err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk worktree_path Issue-7)"; } 2>"$err"
  [ "$out" = "$BATS_TEST_TMPDIR/lab/wt" ]
  [ ! -s "$err" ]
}

@test "state_ctx_get: pinned issue is NOT the shared active_issue — no warning (#879)" {
  state_init volk
  state_set volk active_issue Issue-8
  state_issue_set_many volk Issue-7 str worktree_path ""
  state_set volk worktree_path "$BATS_TEST_TMPDIR/lab/wt"
  local out err="$BATS_TEST_TMPDIR/err"
  export DEVAGENT_ACTIVE_ISSUE=Issue-7
  { out="$(state_ctx_get volk worktree_path)"; } 2>"$err"
  [ -z "$out" ]
  [ ! -s "$err" ]
}

@test "state_ctx_get: table empty and top level empty — no warning (#879)" {
  state_init volk
  state_set volk active_issue Issue-7
  state_issue_set_many volk Issue-7 str worktree_path ""
  local out err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk worktree_path Issue-7)"; } 2>"$err"
  [ -z "$out" ]
  [ ! -s "$err" ]
}

@test "the warning survives the sites' '|| true' idiom (#879)" {
  _wt879_fixture
  local out err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk worktree_path Issue-7 || true)"; } 2>"$err"
  [ -z "$out" ]
  [ "$(grep -c '' "$err")" -eq 1 ]
  grep -qF '[context.Issue-7].worktree_path = ""' "$err"
}

@test "cost: a key other than worktree_path is never checked — 1 call, no warning (#879)" {
  state_init volk
  state_set volk active_issue Issue-7
  state_issue_set_many volk Issue-7 str branch ""
  state_set volk branch feat/7-x
  _wt879_stub
  local out err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk branch Issue-7)"; } 2>"$err"
  [ -z "$out" ]
  [ "$(_wt879_calls)" -eq 1 ]
  [ ! -s "$err" ]
}

@test "cost: a non-empty table hit costs 1 call and never reads the top level (#879 AC3)" {
  state_init volk
  state_set volk active_issue Issue-7
  state_issue_set_many volk Issue-7 str worktree_path "$BATS_TEST_TMPDIR/lab/a"
  state_set volk worktree_path "$BATS_TEST_TMPDIR/lab/b"
  _wt879_stub
  local out
  out="$(state_ctx_get volk worktree_path Issue-7)"
  [ "$out" = "$BATS_TEST_TMPDIR/lab/a" ]
  [ "$(_wt879_calls)" -eq 1 ]
  ! grep -qxF "get $(state_path volk) worktree_path" "$BATS_TEST_TMPDIR/toml-calls"
}

@test "cost: the divergent pinned read costs exactly 3 calls (#879 AC3)" {
  _wt879_fixture
  _wt879_stub
  local out
  export DEVAGENT_ACTIVE_ISSUE=Issue-7
  { out="$(state_ctx_get volk worktree_path)"; } 2>/dev/null
  [ "$(_wt879_calls)" -eq 3 ]
  local f; f="$(state_path volk)"
  grep -qxF "get $f context.Issue-7.worktree_path" "$BATS_TEST_TMPDIR/toml-calls"
  grep -qxF "get $f worktree_path" "$BATS_TEST_TMPDIR/toml-calls"
  grep -qxF "get $f active_issue" "$BATS_TEST_TMPDIR/toml-calls"
}

@test "cost: a table MISS pays at most 2 extra calls and does not warn (#879 B7)" {
  # Unfixed count measured at 3387216: N=3 (table get rc 1, active_issue,
  # top-level worktree_path — state_issue_get's own fallback).
  state_init volk
  state_set volk active_issue Issue-7
  _wt879_stub
  local out err="$BATS_TEST_TMPDIR/err"
  { out="$(state_ctx_get volk worktree_path Issue-7)"; } 2>"$err"
  [ -z "$out" ]
  [ "$(_wt879_calls)" -le 5 ]
  [ ! -s "$err" ]
}

@test "cost: active_tree_resolve pays zero extra on the divergent fixture (#879 S1)" {
  # Unfixed count measured at 3387216: 1 (the table read; source_dir is a
  # config read, not _state_toml).
  mkdir -p "$BATS_TEST_TMPDIR/volk"
  _wt879_fixture
  _wt879_stub
  active_tree_resolve volk Issue-7 2>"$BATS_TEST_TMPDIR/err"
  [ "$ACTIVE_TREE_FROM" = "config" ]
  [ "$(_wt879_calls)" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

# Guard-message fixture: source repo + a linked worktree, cwd inside the
# worktree, no worktree_path recorded — the clause-1 mismatch die.
_wt879_guard_fixture() {
  local src="$BATS_TEST_TMPDIR/volk" wt="$BATS_TEST_TMPDIR/wt879"
  mkdir -p "$src"
  ( cd "$src" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name T \
      && git commit -q --allow-empty -m x && git branch -q wt879 \
      && git worktree add -q "$wt" wt879 )
  state_init volk
  [ -z "${1:-}" ] || state_set volk active_issue "$1"
  cd "$wt" || return 1
}

# Apply the printed remedy exactly as printed: the value from "set
# worktree_path = '<v>'", the top level iff the message names
# "top-level worktree_path", and every [context.<id>].worktree_path it names.
_wt879_apply_remedy() {
  local msg="$1" val ids id
  val="$(printf '%s' "$msg" | sed -n "s/.*(set worktree_path = '\([^']*\)'.*/\1/p")"
  [ -n "$val" ] || return 1
  case "$msg" in *"top-level worktree_path"*) state_set volk worktree_path "$val" ;; esac
  ids="$(printf '%s' "$msg" | grep -o '\[context\.[A-Za-z0-9_-]*\]\.worktree_path' \
      | sed 's/^\[context\.//; s/\]\.worktree_path$//' | sort -u)"
  [ -n "$ids" ] || return 1
  for id in $ids; do state_issue_set_many volk "$id" str worktree_path "$val"; done
}

@test "active_guard_tree: unpinned refusal names BOTH homes for the shared issue (#879 AC1)" {
  _wt879_guard_fixture Issue-7
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "config" ]
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"TREE MISMATCH"* ]]
  [[ "$output" == *"[context.Issue-7].worktree_path"* ]]
  [[ "$output" == *"top-level worktree_path"* ]]
  [[ "$output" == *"$(state_path volk)"* ]]
  [[ "$output" != *"(set worktree_path in"* ]]
}

@test "active_guard_tree: pinned refusal names the PIN's table only (#879 AC1, U2)" {
  _wt879_guard_fixture Issue-7
  export DEVAGENT_ACTIVE_ISSUE=Issue-9
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "config" ]
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"[context.Issue-9].worktree_path"* ]]
  [[ "$output" != *"Issue-7"* ]]
  [[ "$output" != *"top-level worktree_path"* ]]
  [[ "$output" == *"$(state_path volk)"* ]]
}

@test "active_guard_tree: a scan-guessed id is never named — literal <issue> (#879 A5)" {
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3"
  printf -- '- [x] 0. pull\n- [ ] 2. draft\n' > "$BATS_TEST_TMPDIR/devdoc/volk/Issue-3/checklist.md"
  _wt879_guard_fixture
  active_tree_resolve volk
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"[context.<issue>].worktree_path"* ]]
  [[ "$output" != *"Issue-3"* ]]
}

@test "active_guard_tree: following the unpinned remedy recovers FROM=state (#879 B2)" {
  _wt879_guard_fixture Issue-7
  # the incident shape: branch.sh leaves an EMPTY table entry beside the mirror
  state_issue_set_many volk Issue-7 str worktree_path ""
  active_tree_resolve volk
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  _wt879_apply_remedy "$output"
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "state" ]
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
}

@test "active_guard_tree: following the pinned remedy recovers FROM=state (#879 B2)" {
  _wt879_guard_fixture Issue-7
  export DEVAGENT_ACTIVE_ISSUE=Issue-9
  active_tree_resolve volk
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  _wt879_apply_remedy "$output"
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "state" ]
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
}

@test "active_guard_tree: the shared-pin remedy survives a park round trip (#879 B1/B2)" {
  _wt879_guard_fixture Issue-7
  # the incident shape: branch.sh leaves an EMPTY table entry beside the mirror
  state_issue_set_many volk Issue-7 str worktree_path ""
  export DEVAGENT_ACTIVE_ISSUE=Issue-7
  active_tree_resolve volk
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  _wt879_apply_remedy "$output"
  state_context_save volk Issue-7
  state_context_restore volk Issue-7
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "state" ]
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
}

@test "active_guard_tree: the shared-pin remedy recovers FROM=state with the incident's empty table entry (#879 B1)" {
  # The Issue-466 shape, no park: [context.Issue-7].worktree_path = "" wins
  # over the top level for a pinned read (#240), so a top-only remedy (the old
  # message) leaves FROM=config; the printed both-homes remedy must not.
  _wt879_guard_fixture Issue-7
  state_issue_set_many volk Issue-7 str worktree_path ""
  export DEVAGENT_ACTIVE_ISSUE=Issue-7
  active_tree_resolve volk
  run active_guard_tree lib-test
  [ "$status" -eq 1 ]
  _wt879_apply_remedy "$output"
  active_tree_resolve volk
  [ "$ACTIVE_TREE_FROM" = "state" ]
  run active_guard_tree lib-test
  [ "$status" -eq 0 ]
}
