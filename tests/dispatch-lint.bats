#!/usr/bin/env bats
# #360 dispatch-lint.sh — the dispatched-checker report gate.
load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; D="$BATS_TEST_TMPDIR"; }
teardown() { teardown_tmp_devagent_home; }

LINT() { "$PLUGIN_ROOT/scripts/dispatch-lint.sh" "$@"; }

# A well-formed report body (≥5 non-empty lines beyond the 2-line header).
_body() { printf '# Report\n## Section\n- point one\n- point two\n- point three\n- point four\n'; }

@test "dispatch-lint: garbled report (no header, #315 shape) → FAIL (#360)" {
    printf 'the previous response returned some prose\nwith no tool uses at all\n' > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 1"* ]]
}

@test "dispatch-lint: valid inline report → PASS (#360)" {
    { echo 'context: inline'; echo 'model: inherit (session opus)'; _body; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -eq 0 ]
}

@test "dispatch-lint: expected-context mismatch → FAIL (#360)" {
    { echo 'context: inline'; echo 'model: opus'; _body; } > "$D/a.md"
    run LINT "$D/a.md" subagent
    [ "$status" -ne 0 ]
    [[ "$output" == *"context: subagent"* ]]
}

@test "dispatch-lint: tolerant model grammar admits real forms (#360)" {
    # These are the exact shapes real artifacts write — a strict list would reject them.
    for ml in 'model: opus (per-issue checking floor)' \
              'model: fable (per-issue checking marker — binning)' \
              'model: inherit (fallback from opus)' \
              'model: sonnet'; do
        { echo 'context: subagent'; echo "$ml"; _body; } > "$D/a.md"
        run LINT "$D/a.md" subagent
        [ "$status" -eq 0 ] || { echo "rejected: $ml -- $output" >&2; false; }
    done
}

@test "dispatch-lint: bad model line → FAIL (#360)" {
    { echo 'context: inline'; echo 'MODEL WAS opus'; _body; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 2"* ]]
}

@test "dispatch-lint: too-short body → FAIL (#360)" {
    { echo 'context: inline'; echo 'model: opus'; echo 'only one line'; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"body"* ]]
}

@test "dispatch-lint: --class review needs a verdict token (#360)" {
    { echo 'context: subagent'; echo 'model: opus'; _body; } > "$D/noverdict.md"
    run LINT "$D/noverdict.md" subagent --class review
    [ "$status" -ne 0 ]
    [[ "$output" == *"verdict"* ]]

    { echo 'context: subagent'; echo 'model: opus'; _body; echo 'Verdict: SHIP-WITH-NITS'; } > "$D/verdict.md"
    run LINT "$D/verdict.md" subagent --class review
    [ "$status" -eq 0 ]
}

@test "dispatch-lint: accepts the house verdict shapes redmr/review actually emit (#405)" {
    # redmr's mandated Summary count line (no SHIP token) — the 41/79 false-FAIL class.
    { echo 'context: subagent'; echo 'model: inherit'; _body
      echo '## Summary'; echo '0 blocking, 0 major, 1 minor, 3 info'; } > "$D/redmr-count.md"
    run LINT "$D/redmr-count.md" subagent --class redmr
    [ "$status" -eq 0 ]

    # review's "## Blocking" section header (the in-window house format).
    { echo 'context: subagent'; echo 'model: opus'; _body
      echo '## Blocking'; echo 'None.'; } > "$D/review-blocking.md"
    run LINT "$D/review-blocking.md" subagent --class review
    [ "$status" -eq 0 ]

    # A body with NONE of the four verdict signals still FAILs (guard the guard).
    { echo 'context: subagent'; echo 'model: opus'; _body; } > "$D/nosignal.md"
    run LINT "$D/nosignal.md" subagent --class redmr
    [ "$status" -ne 0 ]

    # The '## Blocking' accept must NOT be triggered by redmr's bracketed finding
    # header alone — a bracketed-only body with no count line still FAILs.
    { echo 'context: subagent'; echo 'model: inherit'; _body
      echo '### [BLOCKING] something'; } > "$D/bracketed.md"
    run LINT "$D/bracketed.md" subagent --class redmr
    [ "$status" -ne 0 ]
}

@test "dispatch-lint: unreadable/absent artifact → FAIL (fail-closed) (#360)" {
    run LINT "$D/does-not-exist.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or unreadable"* ]]
}

@test "dispatch-lint: empty artifact → FAIL (#360)" {
    : > "$D/empty.md"
    run LINT "$D/empty.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}
