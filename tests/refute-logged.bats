#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "devagent_refute_logged passes when the needle is absent" {
    printf 'some other line\n' > "$DEVAGENT_STUB_LOG"
    run devagent_refute_logged "git push"
    [ "$status" -eq 0 ]
}

@test "devagent_refute_logged fails (returns 1) when the needle is present" {
    printf 'git push --set-upstream origin x\n' > "$DEVAGENT_STUB_LOG"
    run devagent_refute_logged "git push"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unexpectedly contained"* ]]
}
