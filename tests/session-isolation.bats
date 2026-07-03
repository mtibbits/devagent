#!/usr/bin/env bats
# #240: issue-keyed session isolation. A session is identified by its issue
# PIN (DEVAGENT_ACTIVE_ISSUE / explicit arg) — no session ids. A pinned
# session must never disturb the shared slot another session relies on, and
# its own state lives in [context.<issue>].
load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"

  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-1" "$DEVDOC/Issue-2"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
default_baseline = "origin/main"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"

  # Session A's shared world: Issue-1 active with in-flight keys.
  state_init volk
  state_set volk active_issue Issue-1
  state_set volk issue_dir "$DEVDOC/Issue-1"
  state_set volk branch "feat/1-a"
  state_set volk baseline_sha "aaa111"
  _mk_checklist "$DEVDOC/Issue-1"
}

teardown() { teardown_tmp_devagent_home; }

# Minimal checklist with the structure park/resume/cleanup touch
# (current-step line, a step-20 row, a ## Log section).
_mk_checklist() {
  cat > "$1/checklist.md" <<'CL'
# Issue — Workflow checklist

## Revision 1

- [ ]  0. pull
- [ ]  1. draft
- [ ] 20. cleanup

## Log
CL
}

_shared_view() {  # A's shared slot, as another session would read it
  echo "$(state_get volk active_issue):$(state_get volk branch):$(state_get volk baseline_sha)"
}

@test "pinned pull leaves the whole shared slot untouched (#240 AC1)" {
  before="$(_shared_view)"
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/pull.sh" volk origin 2
  [ "$status" -eq 0 ]
  [ "$(_shared_view)" = "$before" ]
  # And A's in-flight keys were NOT context_clear'd to defaults.
  [ "$(state_get volk branch)" = "feat/1-a" ]
}

@test "unpinned pull still promotes to active (regression) (#240)" {
  run bash "$PLUGIN_ROOT/scripts/pull.sh" volk origin 2
  [ "$status" -eq 0 ]
  [ "$(state_get volk active_issue)" = "Issue-2" ]
}

@test "pinned resume does not restore/delete — table survives, shared slot untouched (#240 improve F1)" {
  # Issue-2 parked with a context snapshot (its live home).
  _mk_checklist "$DEVDOC/Issue-2"
  state_issue_set_many volk Issue-2 str branch "feat/2-b" str baseline_sha "bbb222"
  state_add_parked volk Issue-2
  before="$(_shared_view)"
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-2
  [ "$status" -eq 0 ]
  [ "$(_shared_view)" = "$before" ]
  # The table is the live home — it must SURVIVE resume, not be deleted.
  [ "$(state_get volk context.Issue-2.branch)" = "feat/2-b" ]
  # Parked flag removed.
  run state_list_parked volk
  [[ "$output" != *"Issue-2"* ]]
}

@test "pinned cleanup GCs only its own table; shared slot intact (#240 improve F2)" {
  _mk_checklist "$DEVDOC/Issue-2"
  state_issue_set_many volk Issue-2 str branch "feat/2-b"
  ( mkdir -p "$BATS_TEST_TMPDIR/volk" && cd "$BATS_TEST_TMPDIR/volk" \
    && git -c init.defaultBranch=main init -q \
    && git config user.email t@e.c && git config user.name T \
    && touch x && git add x && git commit -qm i )
  before="$(_shared_view)"
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/cleanup.sh" volk Issue-2
  [ "$status" -eq 0 ]
  [ "$(_shared_view)" = "$before" ]
  # Its own table GC'd; A's top-level untouched.
  run state_get volk context.Issue-2.branch
  [ "$status" -ne 0 ]
}

@test "switch refuses under an env pin (#240 improve F5)" {
  _mk_checklist "$DEVDOC/Issue-2"
  state_issue_set_many volk Issue-2 str branch "feat/2-b"
  state_add_parked volk Issue-2
  DEVAGENT_ACTIVE_ISSUE=Issue-1 run bash "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"pinned"* ]]
  # Nothing half-applied: Issue-1 still active, Issue-2 still parked.
  [ "$(state_get volk active_issue)" = "Issue-1" ]
  run state_list_parked volk
  [[ "$output" == *"Issue-2"* ]]
}

@test "pinned bare park parks the PIN's issue, not the shared one (#240 improve S4)" {
  _mk_checklist "$DEVDOC/Issue-2"
  state_issue_set_many volk Issue-2 str branch "feat/2-b"
  before="$(_shared_view)"
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_shared_view)" = "$before" ]
  run state_list_parked volk
  [[ "$output" == *"Issue-2"* ]]
  [[ "$output" != *"Issue-1"* ]]
}

# ---- The AC1/AC2 interleave probe -------------------------------------------

@test "two-session interleave: B's writes are invisible to A; B reads its OWN values (#240 probe)" {
  # Session B (pinned Issue-2) pulls and step-writes.
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/pull.sh" volk origin 2
  [ "$status" -eq 0 ]
  ( export DEVAGENT_ACTIVE_ISSUE=Issue-2
    state_issue_set_many volk Issue-2 str branch "feat/2-b" str baseline_sha "bbb222" int last_step 6 )
  # A's world byte-unchanged (pointer, keys, and A's bare resolution).
  [ "$(_shared_view)" = "Issue-1:feat/1-a:aaa111" ]
  source "$PLUGIN_ROOT/scripts/lib/active.sh"
  [ "$(active_resolve_issue volk)" = "Issue-1" ]
  # B's POSITIVE path: bare resolution lands Issue-2; reads return B's
  # written values (empty would be the F1/F7 black hole — must fail here).
  ( export DEVAGENT_ACTIVE_ISSUE=Issue-2
    source "$PLUGIN_ROOT/scripts/lib/active.sh"
    [ "$(active_resolve_issue volk)" = "Issue-2" ]
    [ "$(state_issue_get volk Issue-2 branch)" = "feat/2-b" ]
    [ "$(state_issue_get volk Issue-2 last_step)" = "6" ] )
  # And B never observes A's keys.
  [ "$(state_issue_get volk Issue-2 baseline_sha)" = "bbb222" ]
}

@test "pinned RE-pull preserves the session's own live table (#240 review CRIT)" {
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/pull.sh" volk origin 2
  [ "$status" -eq 0 ]
  state_issue_set_many volk Issue-2 str branch "feat/2-b" int last_step 6
  # The documented refresh flow: re-pull the same issue.
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/pull.sh" volk origin 2
  [ "$status" -eq 0 ]
  [ "$(state_get volk context.Issue-2.branch)" = "feat/2-b" ]
}

@test "bare mutating command refuses a scan-guessed issue (#240 review MED)" {
  # Post-cleanup state: no active issue; an incomplete checklist exists that
  # the scan tier would adopt. Mutating scripts must die, not guess.
  state_set volk active_issue ""
  run bash "$PLUGIN_ROOT/scripts/commit.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"no active issue"* ]]
}

@test "cleanup rejects an invalid pin before touching any dir (#240 review MED)" {
  DEVAGENT_ACTIVE_ISSUE='Issue-2/../Issue-1' run bash "$PLUGIN_ROOT/scripts/cleanup.sh" volk
  [ "$status" -ne 0 ]
  # Issue-1's checklist untouched (the traversal previously ran cleanup there).
  run grep -qE '^- \[x\] +20\. cleanup' "$DEVDOC/Issue-1/checklist.md"
  [ "$status" -ne 0 ]
}

@test "pinned step-model honors the leak gate: no tier after cleanup GC (#240 review MED)" {
  printf '[project.volk.step_models]\nchecking = "opus"\n' >> "$DA_HOME/config.toml"
  printf 'fable' > "$DEVDOC/Issue-2/.devagent-step-models"
  # Issue-2 has NO table (as after cleanup GC) — the marker must not leak.
  DEVAGENT_ACTIVE_ISSUE=Issue-2 run bash "$PLUGIN_ROOT/scripts/step-model.sh" volk 13
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}
