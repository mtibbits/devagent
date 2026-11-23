# tests/lib/trust-golden.bash — the #713 no-policy golden scenarios and their
# comparison, shared by tests/trust-golden.bats and the trust tests that must
# replay a golden (an empty location dir, an out-of-scope project). Load after
# lib/bats-helpers, lib/doctor-harness and helpers/common.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

GOLDEN_DIR="$PLUGIN_ROOT/tests/fixtures/trust-golden"

# _golden_norm: stdin → stdout with the run's tmp roots and timestamps tokenised.
_golden_norm() {
  local sed_args=() p
  for p in "${GOLDEN_TMP_ROOTS[@]}"; do
    [ -n "$p" ] || continue
    sed_args+=(-e "s|${p//|/\\|}|<TMP>|g")
  done
  sed "${sed_args[@]}" \
    -E -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?/<TS>/g'
}

# _golden_check <name> <argv-log>: compare (or, under TRUST_GOLDEN_CAPTURE_SHA,
# write) the four fixture files from the last `run --separate-stderr`.
# #715: a fifth kind, `.tree`, is OPT-IN per scenario: "no new files" — `ls -A`
# of GOLDEN_TREE_DIR (the issue dir) and of $DA_HOME/state, plus the sha256 of
# issue.md and .devagent-step-models there. It is checked only when
# $GOLDEN_DIR/<name>.tree exists, and captured only by a scenario that sets
# GOLDEN_TREE=1, so the scenarios without one are untouched.
# TRUST_GOLDEN_CAPTURE_KINDS (default: every kind) limits which kinds a capture
# writes; the other kinds are compared as usual, so a scenario can gain its
# `.tree` while its other fixtures keep their captured-at line.
# shellcheck disable=SC2154  # $output/$status are set by `run --separate-stderr` (bats idiom)
_golden_check() {
  local name="$1" argv_log="$2" kind got kinds=(out err rc argv)
  local tmp="$BATS_TEST_TMPDIR/golden"
  mkdir -p "$tmp"
  printf '%s\n' "$output" | _golden_norm > "$tmp/$name.out"
  printf '%s\n' "$stderr" | _golden_norm > "$tmp/$name.err"
  printf '%s\n' "$status" > "$tmp/$name.rc"
  if [ -f "$argv_log" ]; then _golden_norm < "$argv_log"; fi > "$tmp/$name.argv"
  if [ "${GOLDEN_TREE:-0}" = 1 ] || [ -f "$GOLDEN_DIR/$name.tree" ]; then
    _golden_tree | _golden_norm > "$tmp/$name.tree"
    kinds+=(tree)
  fi
  for kind in "${kinds[@]}"; do
    got="$tmp/$name.$kind"
    if [ -n "${TRUST_GOLDEN_CAPTURE_SHA:-}" ] \
       && [[ " ${TRUST_GOLDEN_CAPTURE_KINDS:-out err rc argv tree} " == *" $kind "* ]]; then
      { printf 'captured-at %s\n' "$TRUST_GOLDEN_CAPTURE_SHA"; cat "$got"; } \
        > "$GOLDEN_DIR/$name.$kind"
      continue
    fi
    if ! diff <(tail -n +2 "$GOLDEN_DIR/$name.$kind") "$got"; then
      echo "golden mismatch: $name.$kind (fixture line 1: $(head -1 "$GOLDEN_DIR/$name.$kind"))" >&2
      return 1
    fi
  done
}

# _golden_tree: the `.tree` kind's body (#715) — what files the run left.
_golden_tree() {
  local d="${GOLDEN_TREE_DIR:?GOLDEN_TREE_DIR unset}" f
  echo "## ls -A issue dir"
  if [ -d "$d" ]; then ls -A "$d"; else echo "(absent)"; fi
  echo "## ls -A state"
  ls -A "$DA_HOME/state"
  for f in issue.md .devagent-step-models; do
    if [ -f "$d/$f" ]; then
      printf '%s  %s\n' "$(sha256sum < "$d/$f" | cut -d' ' -f1)" "$f"
    else
      printf 'absent  %s\n' "$f"
    fi
  done
}

_gh_stub_on_path() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/gh-argv.log"
}

_scenario_pull() {
  setup_tmp_devagent_home
  _gh_stub_on_path
  export GH_STUB_CASE="standard"
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
  GOLDEN_TMP_ROOTS=("$BATS_TEST_TMPDIR" "$DA_HOME")
  GOLDEN_ARGV="$GH_STUB_ARGV_LOG"
  GOLDEN_TREE=1 GOLDEN_TREE_DIR="$DEVDOC/Issue-676"
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
}

# #715: two no-policy pulls across every print site Issue-715 refactors (its
# plan's table C), captured at 1b24202 before any #715 code. The ticket text
# reaches the bytes only through the gh-stub knobs, so `_scenario_pull` stays
# the setup.
# pull-steering crosses S3 (unknown key), S6 (the shim warn and the
# explicit-beats-shim warn), S7 (an unrecognised `tier:*` label), S8's two
# body-beats-label warns, and S9 (a `research` value that is not `required`).
# S8's conflicting-labels die cannot be reached at exit 0; pull.bats covers it.
_scenario_pull_steering() {
  export GH_STUB_BODY_JSON='"Steering fixture.\n\n## Workflow flags\ntier: opus-checking\nchecking-model: fable\nimplementation-model: opus\nresearch: maybe\nzz-unknown: 1\n\nProse after the block."'
  export GH_STUB_LABELS_JSON='[{"name": "tier:impl-sonnet"}, {"name": "tier:check-haiku"}, {"name": "tier:bogus-shape"}, {"name": "bug"}]'
  _scenario_pull
}

# pull-flagsdiag crosses S1 (an inline `<!--` on a key line), S2 (a block
# closed at a non-key line, which prints up to 60 bytes of it) and the
# fence-close warning (flags.sh:287).
_scenario_pull_flagsdiag() {
  # shellcheck disable=SC2016  # the backticks are a literal code fence in the body
  export GH_STUB_BODY_JSON='"Diagnostics fixture.\n\n## Workflow flags\nspike: required <!-- an inline note -->\n\n## Workflow flags\nTier: oneshot, a mis-cased key that closes this block\n\n## Workflow flags\n```text\nresearch: required\n```\n\nThe end."'
  _scenario_pull
}

_scenario_ship() {
  devagent_test_setup
  unset DA_HOME
  ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
    && echo hi > a.txt && git add a.txt \
    && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
  devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
  echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
  echo "kernels: add NEONv8 FMA tier" > "$DEVDOC_DIR/Issue-1/.devagent-title"
  devagent_stub git ""
  devagent_stub gh "https://github.com/acme/testproj/pull/77"
  mkdir -p "$DEVAGENT_TMP/fake-issue"
  cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
  chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
  GOLDEN_TMP_ROOTS=("$DEVAGENT_TMP")
  GOLDEN_ARGV="$DEVAGENT_STUB_LOG"
  run --separate-stderr "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
}

_scenario_next() {
  setup_tmp_devagent_home
  _gh_stub_on_path
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [ ]  4. scope
- [ ]  5. improve
- [ ]  6. prune
- [ ]  7. tighten
- [ ]  8. branch
- [ ]  9. implement
- [ ] 23. cleanup
EOF
  GOLDEN_TMP_ROOTS=("$BATS_TEST_TMPDIR" "$DA_HOME")
  GOLDEN_ARGV="$GH_STUB_ARGV_LOG"
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" volk
}

_scenario_doctor() {
  setup_tmp_devagent_home
  seed_doctor_project
  stub_claude_cli enabled
  _gh_stub_on_path
  GOLDEN_TMP_ROOTS=("$BATS_TEST_TMPDIR" "$DA_HOME")
  # shellcheck disable=SC2034  # read by tests/trust-golden.bats
  GOLDEN_ARGV="$GH_STUB_ARGV_LOG"
  run --separate-stderr "$PLUGIN_ROOT/scripts/doctor.sh" volk
}

# The #714 scenarios: each runs a guarded entry point down its success path,
# across the line where #714 calls quarantine_guard, on devagent_test_setup's
# testproj (active Issue-1, no policy, no marker).
_scenario_t714_setup() {
  devagent_test_setup
  unset DA_HOME
  GOLDEN_TMP_ROOTS=("$DEVAGENT_TMP")
  # shellcheck disable=SC2034  # read by tests/trust-golden.bats
  GOLDEN_ARGV="$DEVAGENT_STUB_LOG"
}

_scenario_park() {
  _scenario_t714_setup
  run --separate-stderr "$DEVAGENT_ROOT/scripts/park.sh" "$TEST_PROJECT"
}

_scenario_unstuck() {
  _scenario_t714_setup
  mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 8 '!'
  printf 'Step:        8 branch\nReason:      fixture\n' > "$DEVDOC_DIR/Issue-1/STUCK"
  run --separate-stderr "$DEVAGENT_ROOT/scripts/unstuck.sh" "$TEST_PROJECT"
}

_scenario_checklist_mark() {
  _scenario_t714_setup
  run --separate-stderr "$DEVAGENT_ROOT/scripts/checklist-mark.sh" "$DEVDOC_DIR/Issue-1" 8 x
}

_scenario_revise() {
  _scenario_t714_setup
  mkdir -p "$DEVDOC_DIR/Issue-1/revisions/r1"
  printf '# acme/testproj#1 — Comments\n\n## Comments (1)\n\n### @alice · 2026-05-20\nnit\n' \
    > "$DEVDOC_DIR/Issue-1/revisions/r1/comments.md"
  run --separate-stderr "$DEVAGENT_ROOT/scripts/revise.sh" "$TEST_PROJECT" Issue-1 --no-chain
}

# cleanup.bats' setup with commit_devdoc = false (no devdoc commit hash).
_scenario_cleanup() {
  _scenario_t714_setup
  devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
  mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 x
  mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 x
  mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 x
  seed_lessons_learned "$DEVDOC_DIR/Issue-1"
  ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x && git branch -f main )
  devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
  mkdir -p "$DEVDOC_DIR/templates"
  printf '%s\n' '# Pothole register' '' '## Bash exit-status & control flow' '- an existing line (Issue-7).' \
    > "$DEVDOC_DIR/templates/potholes.md"
  export TEMPLATE_PATHS_OVERRIDE_potholes="$DEVDOC_DIR/templates/potholes.md"
  export DEVAGENT_PLUGIN_TEMPLATES="$DEVAGENT_TMP/plugin_templates"
  cp -r "$DEVAGENT_ROOT/templates" "$DEVAGENT_PLUGIN_TEMPLATES"
  cp "$DEVDOC_DIR/templates/potholes.md" "$DEVAGENT_PLUGIN_TEMPLATES/potholes.md"
  run --separate-stderr "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
}

# analyze = "none": the family that marks the row without running a tool.
_scenario_analyze() {
  _scenario_t714_setup
  devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.analyze" none
  run --separate-stderr "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT"
}
