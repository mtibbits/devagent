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
