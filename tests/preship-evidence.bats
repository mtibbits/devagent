#!/usr/bin/env bats
# #359 preship-evidence.sh — verification #4. Reads mr.md + suite-count artifact +
# git; no bats/pytest execution, so no nesting concern.
load 'helpers/common'

# Baseline = the seed commit; add one more commit so baseline..HEAD has changes.
setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    echo one > f1.txt && git add -A && git commit -q -m one
    BASELINE="$(git rev-parse HEAD)"
    echo two > f2.txt && git add -A && git commit -q -m two   # 1 file changed vs baseline
    HEAD_SHA="$(git rev-parse HEAD)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE"
    mkdir -p "$DEVDOC_DIR/Issue-1/analysis"
}
teardown() { devagent_test_teardown; }

# $1=head $2=dirty $3=bats-ok $4=plan $5=notok $6=passed $7=failed
_artifact() {
    printf 'head: %s  dirty: %s\nbats: %s/%s notok=%s\npytest: %s passed, %s failed\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# $1=suite-line $2=files-n  (writes an mr.md with an Evidence block)
_mr() {
    { echo '## Summary'; echo 'x'; echo '## Evidence'
      echo "suite: $1"; echo "files: $2 changed"; } > "$DEVDOC_DIR/Issue-1/mr.md"
}
_run() { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1; }

@test "preship-evidence: matching Evidence → rc 0 (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: suite count off by one → nonzero naming both (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "101/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"101/100"* ]] && [[ "$output" == *"100/100"* ]]
}

@test "preship-evidence: stale head → nonzero (#359)" {
    _artifact "deadbeefdeadbeef" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ deadbeefdeadbeef" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"head"* ]]
}

@test "preship-evidence: dirty tree → nonzero (#359)" {
    _artifact "$HEAD_SHA" yes 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"dirty"* ]]
}

@test "preship-evidence: TRUNCATED run (ok<plan, notok=0) → nonzero naming truncation (#406)" {
    # A killed bats run: 500 of 992 ran, 0 failures — looks green, isn't.
    _artifact "$HEAD_SHA" no 500 992 0 20 0
    _mr "500/992 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"truncated"* ]]
    [[ "$output" == *"500 of 992"* ]]
}

@test "preship-evidence: legit-failing run (notok>0) is NOT mislabeled truncated (#406)" {
    # ok<plan because a test FAILED, not because the run was cut short — the notok
    # check reports it; the truncation assert (gated on notok==0) must stay silent.
    _artifact "$HEAD_SHA" no 99 100 1 20 0
    _mr "99/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"notok"* ]]
    [[ "$output" != *"truncated"* ]]
}

@test "preship-evidence: notok>0 → nonzero (#359)" {
    _artifact "$HEAD_SHA" no 99 100 1 20 0
    _mr "99/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"notok"* ]]
}

@test "preship-evidence: files count mismatch → nonzero (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 7   # actual is 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"files"* ]]
}

@test "preship-evidence: unset baseline_sha → die (#359)" {
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha ""
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"baseline"* ]]
}

@test "preship-evidence: mr.md with no Evidence block → warn + rc 0 (#359 back-compat)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

# $1=head  → writes a no-framework (neither bats nor pytest) suite-count artifact
_artifact_none() {
    printf 'head: %s  dirty: no\nbats: (none)\npytest: (none)\n' "$1" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}

@test "preship-evidence: no-framework project reconciles 'suite: none' → rc 0 (#411)" {
    _artifact_none "$HEAD_SHA"
    _mr "none @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: no-framework artifact vs a bats-style Evidence line → nonzero, names 'none @' (#411)" {
    _artifact_none "$HEAD_SHA"
    _mr "0/0 bats, 0 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"none @"* ]]
}

@test "preship-evidence: end-to-end no-framework (run-suite → preship) clean (#411)" {
    # SOURCE_DIR has no tests/*.bats or tests/test_*.py → run-suite writes (none)/(none).
    run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^bats: (none)$'   "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    grep -q '^pytest: (none)$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "none @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}
