#!/usr/bin/env bats
# #713 AC1 (no-policy goldens): with no trust policy on the host, four reference
# entry points print byte-identical stdout/stderr, exit the same, and make the
# same backend calls as at the captured commit. Each scenario copies its source
# test's setup verbatim:
#   pull   — pull.bats "pull origin scaffolds Issue-N dir and writes issue.md"
#   ship   — ship.bats "ship.sh pushes branch, creates MR, fires on_ship transition, stores mr_url"
#   next   — next.bats "next on a skill-backed step prints the slash command to invoke"
#   doctor — doctor.bats "doctor passes on a well-formed setup" (lib/doctor-harness)
#
# Fixtures: tests/fixtures/trust-golden/<name>.{out,err,rc,argv}. Line 1 of each
# is `captured-at <sha>`; comparison starts at line 2. Output is normalised
# (_golden_norm): ISO timestamps → <TS>, the test's tmp roots → <TMP>.
#
# Re-capture: `bash tests/tools/trust-golden-capture.sh` (in the WSL clone).
# SHA rule: it refuses unless scripts/ is clean against HEAD, and stamps HEAD.
# Re-capture only when a change is MEANT to alter no-policy output, and say so
# in the commit; the first capture is 891254c (#713, before any trust code).
#
# Retirement: the four fixtures stay until #902 merges (#902's AC reuses them).
# After that, only "no-policy runs make no whoami/events call" is the standing
# guard and the fixture comparisons may be deleted.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/doctor-harness'
load 'helpers/common'

GOLDEN_DIR="$BATS_TEST_DIRNAME/fixtures/trust-golden"

teardown() {
  teardown_tmp_devagent_home
  devagent_test_teardown
}

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
_golden_check() {
  local name="$1" argv_log="$2" kind got
  local tmp="$BATS_TEST_TMPDIR/golden"
  mkdir -p "$tmp"
  printf '%s\n' "$output" | _golden_norm > "$tmp/$name.out"
  printf '%s\n' "$stderr" | _golden_norm > "$tmp/$name.err"
  printf '%s\n' "$status" > "$tmp/$name.rc"
  if [ -f "$argv_log" ]; then _golden_norm < "$argv_log"; fi > "$tmp/$name.argv"
  for kind in out err rc argv; do
    got="$tmp/$name.$kind"
    if [ -n "${TRUST_GOLDEN_CAPTURE_SHA:-}" ]; then
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
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
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
  GOLDEN_ARGV="$GH_STUB_ARGV_LOG"
  run --separate-stderr "$PLUGIN_ROOT/scripts/doctor.sh" volk
}

@test "trust-golden: pull no-policy output is byte-identical to the 891254c golden" {
  _scenario_pull
  _golden_check pull "$GOLDEN_ARGV"
}

@test "trust-golden: ship no-policy output is byte-identical to the 891254c golden" {
  _scenario_ship
  _golden_check ship "$GOLDEN_ARGV"
}

@test "trust-golden: next no-policy output is byte-identical to the 891254c golden" {
  _scenario_next
  _golden_check next "$GOLDEN_ARGV"
}

@test "trust-golden: doctor no-policy output is byte-identical to the 891254c golden" {
  _scenario_doctor
  _golden_check doctor "$GOLDEN_ARGV"
}

@test "trust-golden: no-policy runs make no whoami/events call" {
  local s all
  for s in pull ship next doctor; do
    # a subshell per scenario: each exports its own HOME/PATH/backend dir.
    ( "_scenario_$s"
      [ "$status" -eq 0 ] || { echo "$s exited $status" >&2; exit 1; }
      if [ -f "$GOLDEN_ARGV" ]; then cat "$GOLDEN_ARGV"; fi > "$BATS_TEST_TMPDIR/argv-$s.log"
      teardown )
  done
  all="$(cat "$BATS_TEST_TMPDIR"/argv-*.log)"
  # positive control: the pull and ship logs recorded their backend calls.
  [[ "$all" == *"[issue] [view]"* ]]
  [[ "$all" == *"gh pr create"* ]]
  run grep -E '\[api\].*\[user\]|/events\]| api .*user|/events' <<<"$all"
  [ "$status" -eq 1 ]
}
