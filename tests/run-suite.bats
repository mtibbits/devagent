#!/usr/bin/env bats
# #359 run-suite.sh. run-suite runs bats internally, which cannot nest inside a
# bats run, so bats is stubbed to controlled TAP (the counting logic — grep '^ok '
# + the 1..N plan line, NEVER the tail, #85 — is what this exercises).
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    mkdir -p "$DEVAGENT_TMP/binstub"
    # Stub bats: 3 planned, 2 ok, 1 not ok — plan(3) != ok-count(2), so a tail-based
    # count would be wrong; run-suite must report 2/3 notok=1.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..3"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "not ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

@test "run-suite writes counts from grep+plan (not tail) and dirty state (#359)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
    grep -q '^pytest: (none)$' "$art"           # no tests/test_*.py present
    grep -qE '^head: [0-9a-f]+  dirty: no$' "$art"
}

@test "run-suite records notok>0 on a failing tree (#359 AC)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q 'notok=1' "$art"
}

@test "run-suite dies loud when bats emits no plan line (#359)" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo "some error, no plan"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plan line"* ]]
}

@test "run-suite dies loud on a TRUNCATED run — plan present but ok+notok<plan (#406)" {
    # bats --tap emits 1..N first; a killed/crashed run leaves a full plan but
    # fewer ok/not-ok lines. Stub that shape: plan 5, only 3 ok, 0 not ok.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..5"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"truncated"* ]]
    [[ "$output" == *"3 of 5"* ]]
}

@test "run-suite does NOT false-die on a legitimately-failing full run (#406)" {
    # plan 3, 2 ok + 1 not ok — ok+notok == plan, so no truncation; a normal
    # (failing) run must still write the artifact and exit 0.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..3"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "not ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
}

# Stub python3 so the pytest branch sees a controlled summary, while DELEGATING
# every non-pytest call (config/state parse `python3 _toml.py`, #116) to the real
# interpreter — resolved before binstub goes on PATH.
_stub_python3_pytest() {
    local summary="$1" real_py3
    real_py3="$(command -v python3)"
    cat > "$DEVAGENT_TMP/binstub/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *pytest*) echo "$summary" ;;
  *) exec "$real_py3" "\$@" ;;
esac
EOF
    chmod +x "$DEVAGENT_TMP/binstub/python3"
}

@test "run-suite parses a line-start pytest summary (count at column 0)" {
    # Regression: pytest -q's summary "285 passed, 9 skipped in Xs" BEGINS with
    # the count. The old sed 's/.*[^0-9]\([0-9]*\) passed/' required a non-digit
    # BEFORE the digits, so a line-start count matched nothing -> recorded 0.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "285 passed, 9 skipped in 0.01s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 285 passed, 0 failed$' "$art"
}

@test "run-suite records pytest: (none) when pytest emits no count at all (false-green guard)" {
    # tests/test_*.py existing does NOT mean pytest can run them: a missing
    # interpreter (Windows Store shim) or a collection error emits no summary.
    # Recording "0 passed, 0 failed" would read "ran clean" for a suite that
    # was never measured; the explicit (none) form is what preship-evidence's
    # no-framework reconciliation requires. (Behavior landed alongside #572;
    # authored as a concurrent operator edit, pinned by this test.)
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "pytest exploded: no summary counts in this output"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: (none)$' "$art"
}

@test "run-suite parses a mixed failed+passed pytest summary (order-independent)" {
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "3 failed, 282 passed in 0.02s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 282 passed, 3 failed$' "$art"
}

@test "run-suite artifact name honors DEVAGENT_DATE_OVERRIDE (#413/#338)" {
    export DEVAGENT_DATE_OVERRIDE=2020-02-02
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/2020-02-02-suite-count.txt" ]
}

@test "#571 AC3: the head:/dirty: stamp survives, and the artifact records its tree" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    # head: is the FIRST data line and carries BOTH fields (register Issue-572)
    run head -1 "$art"
    printf '%s\n' "$output" | grep -qE '^head: [0-9a-f]+  dirty: (yes|no)$'
    # tree: is an IDENTITY — canonical (pwd -P) on both sides; precise count,
    # never -ne 0 (register Issue-337)
    run grep -c '^tree: ' "$art"
    [ "$output" -eq 1 ]
    grep -q "^tree: $(cd "$SOURCE_DIR" && pwd -P)$" "$art"
}
