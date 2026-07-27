#!/usr/bin/env bats
# #313: the recovery scripts (stuck/unstuck/resume) used gawk's 3-arg
# match($0, /re/, arr) capture-array form, which mawk PARSE-ERRORS on (rc=2).
# On a mawk-default box (Debian/Raspberry Pi `awk` alternative) the scripts died
# before doing their work — and the stuck machinery has never once fired across
# the project's history, so nothing caught it. These tests pin mawk-safety two
# ways: a static recurrence guard over the whole scripts/ tree, and an e2e run
# of each recovery script with `awk` forced to mawk on PATH.

load 'lib/bats-helpers'

setup() {
  # Hermetic against the operator's ambient pins (bats-helpers doesn't unset
  # them; that is #322's remit — do not depend on it here).
  unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [~]  4. scope
- [ ]  5. improve
## Log
EOF

  # PATH shim: force a bare `awk` (in the scripts AND every lib they source) to
  # resolve to mawk, so the e2e tests exercise the real mawk parser.
  SHIMBIN="$BATS_TEST_TMPDIR/shimbin"
  mkdir -p "$SHIMBIN"
  cat > "$SHIMBIN/awk" <<'SHIM'
#!/usr/bin/env bash
exec mawk "$@"
SHIM
  chmod +x "$SHIMBIN/awk"
}

teardown() { teardown_tmp_devagent_home; }

# --- Static recurrence guard (whole tree; #73/#313) ------------------------
@test "no gawk 3-arg match(expr, /re/, arr) capture form anywhere in scripts/ (#313)" {
  # mawk parse-errors on the capture-array third argument. This targets the
  # regex-literal form precisely: a 2-arg match(x, /re/) has no ", ident" tail
  # and is not flagged. NOTE: it cannot tell code from a comment, so prose that
  # illustrates the anti-pattern must use the bare-letter form "match(s, r, arr)"
  # (no /regex/ literal) to stay clear of the guard — the convention the
  # checklist.sh doc comments already follow.
  run grep -rnE 'match\([^,]+, */[^/]*/, *[A-Za-z_]' "$PLUGIN_ROOT/scripts"
  if [ "$status" -eq 0 ]; then
    echo "gawk-only 3-arg match() capture form (mawk parse-errors) found:" >&2
    echo "$output" >&2
    return 1
  fi
}

# --- e2e: each recovery script runs under mawk-as-awk ------------------------
@test "stuck.sh runs under mawk and marks [!] + writes STUCK (#313 born-red)" {
  command -v mawk >/dev/null 2>&1 || skip "mawk not installed"
  PATH="$SHIMBIN:$PATH" run "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked on upstream"
  [ "$status" -eq 0 ]
  grep -E '^- \[!\]  4\. scope' "$DEVDOC/Issue-676/checklist.md"
  [ -f "$DEVDOC/Issue-676/STUCK" ]
  # The "last good" walk-back (last [x] step before the current one) must still
  # resolve — step 2 (draft), not step 0 — proving the number extraction works.
  grep -q 'Last good: *step 2 draft' "$DEVDOC/Issue-676/STUCK"
}

@test "unstuck.sh runs under mawk and flips [!] back to [~] (#313 born-red)" {
  command -v mawk >/dev/null 2>&1 || skip "mawk not installed"
  # Arrange a stuck state without depending on mawk (normal awk in setup path).
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  [ -f "$DEVDOC/Issue-676/STUCK" ]
  PATH="$SHIMBIN:$PATH" run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  grep -E '^- \[~\]  4\. scope' "$DEVDOC/Issue-676/checklist.md"
}

@test "resume.sh runs under mawk and flips [P] back to [~] (#313 born-red)" {
  command -v mawk >/dev/null 2>&1 || skip "mawk not installed"
  # Park (normal awk) to produce a valid [P] + [parked] state, then resume
  # under mawk so only resume.sh's parser is under test.
  "$PLUGIN_ROOT/scripts/park.sh" volk
  grep -E '^- \[P\]' "$DEVDOC/Issue-676/checklist.md"
  PATH="$SHIMBIN:$PATH" run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  # The parked step was flipped back off [P] (the awk found its number).
  run grep -E '^- \[P\]' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -ne 0 ]
}
