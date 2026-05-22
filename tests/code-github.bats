#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "code/github.sh push-branch invokes git push remote branch" {
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" push-branch origin fix/1-foo
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin fix/1-foo"
}
