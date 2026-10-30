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
  # The stub backend prints $CI_STUB_OUT, writes $CI_STUB_ERR to stderr, exits $CI_STUB_RC;
  # with $CI_STUB_VERBS set it appends the verb it was asked for.
  cat > "$BATS_TEST_TMPDIR/code/stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in mr-checks|mr-view) ;; *) exit 2 ;; esac   # #885: ci_read_view reads mr-view
[ -z "${CI_STUB_VERBS:-}" ] || printf '%s
' "$1" >> "$CI_STUB_VERBS"
[ -z "${CI_STUB_SLEEP:-}" ] || exec sleep "$CI_STUB_SLEEP"
printf '%s' "${CI_STUB_OUT:-}"
[ -z "${CI_STUB_ERR:-}" ] || printf '%s\n' "$CI_STUB_ERR" >&2
exit "${CI_STUB_RC:-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/code/stub.sh"
  export DEVAGENT_CODE_BACKEND_DIR="$BATS_TEST_TMPDIR/code"
  for l in paths io config state active checklist log ci; do
    # shellcheck source=/dev/null
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

@test "#782 CI UNKNOWN line quotes the backend's last stderr line; the lines above it go to stderr" {
  CI_STUB_RC=1 CI_STUB_ERR=$'HTTP 401: Bad credentials\n\ngh exited 1' \
    ci_read volk Issue-676 "$URL" 2>"$BATS_TEST_TMPDIR/err"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: gh exited 1" ]
  grep -qF 'ci: stub mr-checks: HTTP 401: Bad credentials' "$BATS_TEST_TMPDIR/err"
  run grep -qF 'gh exited 1' "$BATS_TEST_TMPDIR/err"
  [ "$status" -ne 0 ]
}

@test "#782 CI UNKNOWN with a silent backend names its exit" {
  CI_STUB_RC=5 ci_read volk Issue-676 "$URL" 2>"$BATS_TEST_TMPDIR/err"
  [ "$CI_LINE" = "CI UNKNOWN: $URL: stub mr-checks exited 5" ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "#782 CI UNKNOWN on a read past the bound" {
  local t0=$SECONDS
  DEVAGENT_CI_READ_SECS=1 CI_STUB_SLEEP=30 ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: timed out after 1s" ]
  [ $((SECONDS - t0)) -lt 8 ]
}

@test "#782 an unset backend reads CI NOT CHECKED: (none)" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/config.toml" project.volk.code_source.backend
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = notchecked ]
  [ "$CI_LINE" = "CI NOT CHECKED: (none) has no mr-checks" ]
}

@test "#782 a configured backend whose script is missing is UNKNOWN, not NOT CHECKED" {
  rm "$BATS_TEST_TMPDIR/code/stub.sh"
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: stub.sh not found or not executable" ]
  ci_verdict
  [ "$CI_VERDICT" = hold ]
}

@test "#782 a fail line whose link is - keeps its [CONCLUSION] bracket and prints no link" {
  _out $'fail\tdeploy\t-\tCANCELLED' $'fail\tlint\t-\tFAILURE'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = red ]
  [ "$CI_LINE" = "CI FAILED: $URL (head a1b2c3d): deploy [CANCELLED]; lint" ]
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
  [ "$CI_SEEN_AT" = "$at" ]
  state_issue_set_many volk Issue-676 str ci_seen_at 1000
  ci_read volk Issue-676 "$URL"                       # same head: no rewrite
  [ "$(state_issue_get volk Issue-676 ci_seen_at)" = 1000 ]
  [ "$CI_SEEN_AT" = 1000 ]
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
    ci_verdict
    [ "$CI_VERDICT" = "$want" ] || { echo "$r gave $CI_VERDICT"; false; }
  done
}

@test "#782 ci_verdict: none inside grace is hold, outside is proceed" {
  CI_RESULT=none
  CI_SEEN_AT="$(date +%s)"
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict
  [ "$CI_VERDICT" = hold ]
  CI_SEEN_AT="$(( $(date +%s) - 1000 ))"
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict
  [ "$CI_VERDICT" = proceed ]
}

@test "#782 ci_verdict: none with an empty or garbage CI_SEEN_AT holds" {
  CI_RESULT=none; CI_SEEN_AT=""
  ci_verdict
  [ "$CI_VERDICT" = hold ]
  CI_SEEN_AT="12x"
  ci_verdict
  [ "$CI_VERDICT" = hold ]
  # ci_read hands a garbled stored clock through unchanged, so it holds too.
  _out
  state_issue_set_many volk Issue-676 str ci_seen_head "$HEAD40" str ci_seen_at "12x"
  ci_read volk Issue-676 "$URL"
  ci_verdict
  [ "$CI_VERDICT" = hold ]
}

@test "#782 ci_verdict: none after a failed head write holds, not judged by another head's clock" {
  _out
  state_issue_set_many volk Issue-676 str ci_seen_head 0000000000000000000000000000000000000001 \
                                      str ci_seen_at "$(( $(date +%s) - 1000 ))"
  state_ctx_set_many() { return 1; }
  ci_read volk Issue-676 "$URL" 2>/dev/null
  [ "$CI_RESULT" = none ]
  [ -z "$CI_SEEN_AT" ]
  DEVAGENT_CI_GRACE_SECS=600 ci_verdict
  [ "$CI_VERDICT" = hold ]
}

# --- ci_read_view (#885) -------------------------------------------------------
# _view_out [extra-lines...]: an mr-view body: one pass check, every singleton kind,
# two closes and two trailers, then the given lines.
_view_out() {
  _out $'pass\tlint\thttps://x/1' $'draft\tfalse' $'base\tmain' $'mergeable\tMERGEABLE' \
       $'mergestate\tCLEAN' $'automerge\toff' $'queue\tfalse' $'number\t9' \
       $'title\tFix the volk thing' $'mergecommit\t-' $'closes\tacme/volk\t676' \
       $'closes\tOther-Org/tracker\t12' $'trailer\tSigned-off-by: A <a@x.org>' \
       $'trailer\tCo-authored-by: B <b@x.org>' $'commits\t3\t3' "$@"
}

# _view_without <kind>: _view_out with the <kind> line dropped.
_view_without() {
  _view_out
  CI_STUB_OUT="$(grep -v "^$1"$'\t' <<<"$CI_STUB_OUT")"$'\n'
  export CI_STUB_OUT
}

@test "#885 ci_read still rejects a draft line" {
  _out $'pass\tlint\thttps://x/1' $'draft\tfalse'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: unrecognised mr-checks output" ]
  _out $'pass\tlint\thttps://x/1' $'trailer\tSigned-off-by: A <a@x.org>'
  ci_read volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
}

@test "#885 ci_read_view sets MV_*" {
  bounded_call() { printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/secs"; shift; "$@"; }
  export CI_STUB_VERBS="$BATS_TEST_TMPDIR/verbs"
  _view_out
  ci_read_view volk Issue-676 "$URL"
  [ "$(cat "$CI_STUB_VERBS")" = mr-view ]
  [ "$(cat "$BATS_TEST_TMPDIR/secs")" = 20 ]
  [ "$MV_OK" = 1 ]
  [ -z "$MV_ERR" ]
  [ "$MV_DRAFT" = false ]
  [ "$MV_BASE" = main ]
  [ "$MV_MERGEABLE" = MERGEABLE ]
  [ "$MV_MERGESTATE" = CLEAN ]
  [ "$MV_AUTOMERGE" = off ]
  [ "$MV_QUEUE" = false ]
  [ "$MV_NUMBER" = 9 ]
  [ "$MV_TITLE" = "Fix the volk thing" ]
  [ "$MV_MERGECOMMIT" = - ]
  [ "${#MV_CLOSES[@]}" -eq 2 ]
  [ "${MV_CLOSES[0]}" = "acme/volk#676" ]
  [ "${MV_CLOSES[1]}" = "Other-Org/tracker#12" ]
  [ "${#MV_TRAILERS[@]}" -eq 2 ]
  [ "${MV_TRAILERS[0]}" = "Signed-off-by: A <a@x.org>" ]
  [ "${MV_TRAILERS[1]}" = "Co-authored-by: B <b@x.org>" ]
  [ "$MV_COMMITS_TOTAL" = 3 ]
  [ "$MV_COMMITS_READ" = 3 ]
  # the CI globals are ci_read's, from the same lines
  [ "$CI_RESULT" = green ]
  [ "$CI_HEAD" = "$HEAD40" ]
  [ "$CI_LINE" = "CI PASSED: 1 checks on $URL (head a1b2c3d)" ]
  [ "$(state_issue_get volk Issue-676 ci_seen_head)" = "$HEAD40" ]
  # its own knob bounds the read; ci_read keeps DEVAGENT_CI_READ_SECS and mr-checks
  DEVAGENT_MERGEMR_READ_SECS=7 DEVAGENT_CI_READ_SECS=9 ci_read_view volk Issue-676 "$URL"
  [ "$(cat "$BATS_TEST_TMPDIR/secs")" = 7 ]
  DEVAGENT_MERGEMR_READ_SECS=7 DEVAGENT_CI_READ_SECS=9 ci_read volk Issue-676 "$URL"
  [ "$(cat "$BATS_TEST_TMPDIR/secs")" = 9 ]
  [ "$(tail -n 1 "$CI_STUB_VERBS")" = mr-checks ]
  # a merged PR's merge commit
  export CI_STUB_OUT="${CI_STUB_OUT//$'state\topen'/$'state\tmerged'}"
  CI_STUB_OUT="${CI_STUB_OUT//$'mergecommit\t-'/$'mergecommit\t0123456789abcdef0123456789abcdef01234567'}"
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 1 ]
  [ "$CI_RESULT" = merged ]
  [ "$MV_MERGECOMMIT" = 0123456789abcdef0123456789abcdef01234567 ]
}

@test "#885 ci_read_view missing mergestate → MV_OK=0" {
  _view_without mergestate
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "unrecognised mr-view output: mergestate missing" ]
  local k
  for k in draft base mergeable automerge queue number title mergecommit commits; do
    _view_without "$k"
    ci_read_view volk Issue-676 "$URL"
    [ "$MV_OK" = 0 ] || { echo "no $k gave MV_OK=$MV_OK"; false; }
    [ "$MV_ERR" = "unrecognised mr-view output: $k missing" ]
  done
  # an invalid value, and a repeated singleton, fail closed too
  _view_out
  CI_STUB_OUT="${CI_STUB_OUT//$'mergeable\tMERGEABLE'/$'mergeable\tMAYBE'}"
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "unrecognised mr-view output: mergeable invalid" ]
  _view_out $'number\t10'
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "unrecognised mr-view output: number repeated" ]
  _view_out $'commits\t1x\t1'
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 0 ]
}

@test "#885 ci_read_view: a kind outside the named set is bad" {
  _view_out $'labels\tbug'
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 0 ]
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: unrecognised mr-view output" ]
  [ "$MV_ERR" = "unrecognised mr-view output" ]
}

@test "#885 ci_read_view timeout → unknown 'timed out after Ns'" {
  local t0=$SECONDS
  _view_out
  DEVAGENT_MERGEMR_READ_SECS=1 CI_STUB_SLEEP=30 ci_read_view volk Issue-676 "$URL"
  [ "$CI_RESULT" = unknown ]
  [ "$CI_LINE" = "CI UNKNOWN: $URL: timed out after 1s" ]
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "timed out after 1s" ]
  [ $((SECONDS - t0)) -lt 8 ]
}

@test "#885 ci_read_view: a failed read clears the last read's MV_*; no verb is notchecked" {
  _view_out
  ci_read_view volk Issue-676 "$URL"
  [ "$MV_OK" = 1 ]
  CI_STUB_RC=1 CI_STUB_ERR='gh: HTTP 502' ci_read_view volk Issue-676 "$URL" 2>/dev/null
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "gh: HTTP 502" ]
  [ -z "$MV_MERGESTATE" ]
  [ "${#MV_CLOSES[@]}" -eq 0 ]
  [ "${#MV_TRAILERS[@]}" -eq 0 ]
  CI_STUB_RC=2 ci_read_view volk Issue-676 "$URL"
  [ "$CI_RESULT" = notchecked ]
  [ "$CI_LINE" = "CI NOT CHECKED: stub has no mr-view" ]
  [ "$MV_OK" = 0 ]
  [ "$MV_ERR" = "stub has no mr-view" ]
}
