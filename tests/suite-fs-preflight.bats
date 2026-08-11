#!/usr/bin/env bats
# #565: run-suite.sh's only product is a provenance artifact that
# preship-evidence.sh consumes as authority. On a filesystem where chmod is a
# no-op (Windows noacl NTFS) a suite that asserts file modes fails wholesale,
# so an artifact written there is authoritative-looking false evidence
# (Issue-550's lesson). run-suite.sh therefore refuses.
#
# These tests drive run-suite.sh END TO END rather than grepping its source: a
# structural assertion would pass on `if false; then …probe…; fi` and redden on
# any innocuous reflow. The probe itself (posix_modes_representable, #289) is
# tested in tests/lib_secrets.bats.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p "$DEVAGENT_TMP/binstub"
    # Stub bats so run-suite's own bats branch is deterministic and fast.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

_seed_suite() {
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
}

# The guard must stay SILENT where its trigger is legitimately absent
# (#Fork-195) — a project with no suite at all still gets its artifact.
@test "#565: a tests-less tree still writes its artifact (preflight does not fire)" {
    git commit -q --allow-empty -m "no tests here"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: (none)$' "$art"
}

@test "#565: a tree WITH a suite still writes its artifact where chmod works" {
    _seed_suite
    local t="$SOURCE_DIR/.pc"; : > "$t"; chmod 600 "$t"
    [ "$(stat -c '%a' "$t" 2>/dev/null)" = 600 ] || skip "chmod is a no-op here; the die branch is asserted below"
    rm -f "$t"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

# Drives the real refusal branch on ANY platform, using the technique
# tests/lib_secrets.bats already uses for this probe: stub chmod to a no-op and
# stat to report 644, so a probe file reads back != 600.
@test "#565: run-suite REFUSES and writes NO artifact when chmod is a no-op" {
    _seed_suite
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0'   > "$DEVAGENT_TMP/binstub/chmod"
    printf '%s\n' '#!/usr/bin/env bash' 'echo 644' > "$DEVAGENT_TMP/binstub/stat"
    chmod +x "$DEVAGENT_TMP/binstub/chmod" "$DEVAGENT_TMP/binstub/stat"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"chmod is a NO-OP"* ]]
    [[ "$output" == *"false evidence"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "#565: the refusal names the WSL remedy and a README section that exists" {
    # Two-sided constant (#106): the message points at a heading, so a rename
    # must redden here instead of silently misdirecting the reader.
    run grep -q '^## Running the test suite$' "$DEVAGENT_ROOT/README.md"
    [ "$status" -eq 0 ]
    run grep -q "Running the test suite" "$DEVAGENT_ROOT/scripts/run-suite.sh"
    [ "$status" -eq 0 ]
    run grep -q 'WSL clone on ext4' "$DEVAGENT_ROOT/scripts/run-suite.sh"
    [ "$status" -eq 0 ]
}
