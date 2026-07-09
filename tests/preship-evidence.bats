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
    sed -i "s|^baseline_sha.*|baseline_sha   = \"$BASELINE\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
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
    sed -i 's|^baseline_sha.*|baseline_sha   = ""|' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
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
