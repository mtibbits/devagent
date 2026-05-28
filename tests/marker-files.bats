#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "branch.sh fails with clear error when .devagent-type is missing" {
    echo "make widgets faster" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    # Deliberately do NOT write .devagent-type
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *".devagent-type"* ]]
    [[ "$output" == *"issue type not classified"* ]]
}

@test "branch.sh fails with clear error when .devagent-title is missing" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    # Deliberately do NOT write .devagent-title
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *".devagent-title"* ]]
    [[ "$output" == *"issue title not captured"* ]]
}

@test "branch.sh succeeds when both marker files are present" {
    echo "bug" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "fix null pointer in parser" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"fix/1-fix-null-pointer-in-parser"* ]]
}
