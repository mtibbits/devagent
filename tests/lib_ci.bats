#!/usr/bin/env bats
# Unit tests for scripts/lib/ci.sh (#782): read, classify, format, log, verdict.
# The backend is a stub script in DEVAGENT_CODE_BACKEND_DIR, so these legs pin
# ci.sh alone; tests/next.bats and tests/mergetoall.bats drive the real
# code/github.sh through the gh-stub.

load 'lib/bats-helpers'

URL=https://github.com/acme/volk/pull/9
HEAD40=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  ISSUE_DIR="$DEVDOC/Issue-676"
  mkdir -p "$ISSUE_DIR" "$BATS_TEST_TMPDIR/code"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.code_source]
backend = "stub"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$ISSUE_DIR"
EOF
  printf '%s\n' '- [x] 18. ship' '- [ ] 20. updatewbs' '' '## Log' > "$ISSUE_DIR/checklist.md"
  # The stub backend prints $CI_STUB_OUT, writes $CI_STUB_ERR to stderr, exits $CI_STUB_RC.
  cat > "$BATS_TEST_TMPDIR/code/stub.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = mr-checks ] || exit 2
[ -z "${CI_STUB_SLEEP:-}" ] || exec sleep "$CI_STUB_SLEEP"
printf '%s' "${CI_STUB_OUT:-}"
[ -z "${CI_STUB_ERR:-}" ] || printf '%s\n' "$CI_STUB_ERR" >&2
exit "${CI_STUB_RC:-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/code/stub.sh"
  export DEVAGENT_CODE_BACKEND_DIR="$BATS_TEST_TMPDIR/code"
  for l in paths io config state active checklist log ci; do
    source "$PLUGIN_ROOT/scripts/lib/$l.sh"
  done
}

teardown() { teardown_tmp_devagent_home; }

# _out <bucket-lines...>: a grammar-conformant mr-checks body for $HEAD40, state open.
_out() {
  local l body=$'state\topen\nhead\t'"$HEAD40"$'\n'
  for l in "$@"; do body+="$l"$'\n'; done
  export CI_STUB_OUT="$body"
}

_ci_lines() { grep -c '^- .*  ci: ' "$ISSUE_DIR/checklist.md" || true; }

@test "#782 ci_read classifies red over pending" {
  _out $'fail\tlint\thttps://x/1\tFAILURE' $'pending\tbuild\thttps://x/2'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = red ]
  [ "$CI_HEAD" = "$HEAD40" ]
}

@test "#782 CI PASSED line" {
  _out $'pass\tlint\thttps://x/1' $'pass\tbuild\thttps://x/2'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = green ]
  [ "$CI_LINE" = "CI PASSED: 2 checks on $URL (head a1b2c3d)" ]
}

@test "#782 CI PENDING line names only the running checks" {
  _out $'pass\tlint\thttps://x/1' $'pending\tbuild\thttps://x/2' $'pending\tdocs\thttps://x/3'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = pending ]
  [ "$CI_LINE" = "CI PENDING: 2 of 3 checks still running on $URL (head a1b2c3d): build, docs" ]
}

@test "#782 CI FAILED line: a FAILURE carries no bracket, any other conclusion does" {
  _out $'fail\tbats shard 2 of 4\thttps://x/1\tFAILURE' $'pending\tbuild\thttps://x/2' \
       $'fail\tdeploy\thttps://x/3\tACTION_REQUIRED' $'fail\tsc\thttps://x/4\tERROR'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = red ]
  [ "$CI_LINE" = "CI FAILED: $URL (head a1b2c3d): bats shard 2 of 4 https://x/1; deploy [ACTION_REQUIRED] https://x/3; sc https://x/4" ]
}

@test "#782 CI NONE line" {
  _out
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = none ]
  [ "$CI_LINE" = "CI NONE: no checks reported on $URL (head a1b2c3d)" ]
}

@test "#782 CI UNKNOWN line quotes the backend's last stderr line" {
  CI_STUB_RC=1 CI_STUB_ERR=$'some gh noise\ngh exited 1' ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: gh exited 1" ]
}

@test "#782 CI UNKNOWN with a silent backend names its exit" {
  CI_STUB_RC=5 ci_read volk Issue-676 "$URL"
  [ "$CI_LINE" = "CI UNKNOWN: $URL: stub mr-checks exited 5" ]
}

@test "#782 CI UNKNOWN on a read past the bound" {
  local t0=$SECONDS
  DEVAGENT_CI_READ_SECS=1 CI_STUB_SLEEP=30 ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: timed out after 1s" ]
  [ $((SECONDS - t0)) -lt 8 ]
}

@test "#782 CI NOT CHECKED line, and an unset backend reads (none)" {
  rm "$BATS_TEST_TMPDIR/code/stub.sh"
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = notchecked ]
  [ "$CI_LINE" = "CI NOT CHECKED: stub has no mr-checks" ]
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/config.toml" project.volk.code_source.backend
  ci_read volk Issue-676 "$URL"
  [ "$CI_LINE" = "CI NOT CHECKED: (none) has no mr-checks" ]
}

@test "#782 ci_read: exit 78 and exit 2 are notchecked" {
  CI_STUB_RC=78 ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = notchecked ]
  CI_STUB_RC=2 ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = notchecked ]
}

@test "#782 ci_read: non-grammar stdout is unknown, never none" {
  export CI_STUB_OUT=$'state\topen\n'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: unrecognised mr-checks output" ]
  _out $'skipped\tlint\thttps://x/1'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
}

@test "#782 ci_read: merged and closed print no line" {
  export CI_STUB_OUT=$'state\tmerged\nhead\t'"$HEAD40"$'\nfail\tlint\thttps://x/1\tFAILURE\n'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = merged ]
  [ -z "$CI_LINE" ]
  export CI_STUB_OUT=$'state\tclosed\nhead\t'"$HEAD40"$'\n'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = closed ]
  run ci_report "$ISSUE_DIR"
  [ -z "$output" ]
}

@test "#782 ci_read records ci_seen_head/ci_seen_at once per head" {
  local t0; t0="$(date +%s)"
  _out
  ci_read volk Issue-676 "$URL"
  [ "$(state_issue_get volk Issue-676 ci_seen_head)" = "$HEAD40" ]
  local at; at="$(state_issue_get volk Issue-676 ci_seen_at)"
  [[ "$at" =~ ^[0-9]+$ ]]
  [ "$at" -ge "$t0" ]
  state_issue_set_many volk Issue-676 str ci_seen_at 1000
  ci_read volk Issue-676 "$URL"                       # same head: no rewrite
  [ "$(state_issue_get volk Issue-676 ci_seen_at)" = 1000 ]
}

@test "#782 ci_report logs once per (result, head)" {
  _out $'pending\tbuild\thttps://x/2'
  ci_read volk Issue-676 "$URL"; ci_report "$ISSUE_DIR" >/dev/null
  ci_read volk Issue-676 "$URL"; ci_report "$ISSUE_DIR" >/dev/null
  [ "$(_ci_lines)" -eq 1 ]
  _out $'fail\tbuild\thttps://x/2\tFAILURE'
  ci_read volk Issue-676 "$URL"
  run ci_report "$ISSUE_DIR"
  [ "$output" = "$CI_LINE" ]
  [ "$(_ci_lines)" -eq 2 ]
  grep -qF "  ci: red a1b2c3d — CI FAILED: $URL" "$ISSUE_DIR/checklist.md"
}

@test "#782 ci_report survives a checklist with no ## Log" {
  printf '%s\n' '- [x] 18. ship' > "$ISSUE_DIR/checklist.md"
  _out $'pass\tlint\thttps://x/1'
  ci_read volk Issue-676 "$URL"
  run ci_report "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "CI PASSED: 1 checks on $URL (head a1b2c3d)" ]
}

@test "#782 ci_gate_resolve: report by default, [defaults] applies, project wins, bad value dies with the exact message" {
  ci_gate_resolve volk
  [ "$CI_GATE" = report ]
  printf '\n[defaults]\nci_gate = "block"\n' >> "$DA_HOME/config.toml"
  ci_gate_resolve volk
  [ "$CI_GATE" = block ]
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.ci_gate '"off"'
  ci_gate_resolve volk
  [ "$CI_GATE" = off ]
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.ci_gate '"maybe"'
  run ci_gate_resolve volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"ci_gate must be report, block or off (got 'maybe')"* ]]
}

@test "#782 DEVAGENT_CI_READ_SECS=999999 warns and uses 20" {
  bounded_call() { printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/secs"; shift; "$@"; }
  _out
  DEVAGENT_CI_READ_SECS=999999 ci_read volk Issue-676 "$URL" 2>"$BATS_TEST_TMPDIR/err"
  [ "$(cat "$BATS_TEST_TMPDIR/secs")" = 20 ]
  grep -q 'DEVAGENT_CI_READ_SECS' "$BATS_TEST_TMPDIR/err"
  [ "$CI_RESULT" = none ]
}

@test "#782 ci_verdict: red, hold and proceed by result" {
  local r want
  for r in red:red pending:hold unknown:hold green:proceed notchecked:proceed merged:proceed closed:proceed; do
    CI_RESULT="${r%%:*}"; want="${r#*:}"
    ci_verdict volk Issue-676
    [ "$CI_VERDICT" = "$want" ] || { echo "$r gave $CI_VERDICT"; false; }
  done
}

@test "#782 ci_verdict: none inside grace is hold, outside is proceed" {
  CI_RESULT=none; CI_HEAD="$HEAD40"
  state_issue_set_many volk Issue-676 str ci_seen_head "$HEAD40" str ci_seen_at "$(date +%s)"
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict volk Issue-676
  [ "$CI_VERDICT" = hold ]
  state_issue_set_many volk Issue-676 str ci_seen_at "$(( $(date +%s) - 1000 ))"
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict volk Issue-676
  [ "$CI_VERDICT" = proceed ]
}

@test "#782 ci_verdict: none with an empty or garbage ci_seen_at holds" {
  CI_RESULT=none
  ci_verdict volk Issue-676
  [ "$CI_VERDICT" = hold ]
  state_issue_set_many volk Issue-676 str ci_seen_at "12x"
  ci_verdict volk Issue-676
  [ "$CI_VERDICT" = hold ]
}

@test "#782 ci_verdict: none judged by another head's ci_seen_at holds" {
  # A failed head write must not let the new head inherit the old head's clock.
  CI_RESULT=none; CI_HEAD="$HEAD40"
  state_issue_set_many volk Issue-676 str ci_seen_head 0000000000000000000000000000000000000001 \
                                      str ci_seen_at "$(( $(date +%s) - 1000 ))"
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict volk Issue-676
  [ "$CI_VERDICT" = hold ]
}
