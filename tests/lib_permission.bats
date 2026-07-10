#!/usr/bin/env bats
# #336 — direct unit coverage for the permission gate (spec §8). The default-DENY
# path (absent permissions key → config_get_project_field || echo false) is the
# safety boundary and had no pin; a regression to default-allow would ship green.
load 'helpers/common'

setup() {
    devagent_test_setup
    R="$DEVAGENT_ROOT"
    # shellcheck disable=SC1090
    . "$R/scripts/lib/paths.sh"; . "$R/scripts/lib/io.sh"
    . "$R/scripts/lib/config.sh"; . "$R/scripts/lib/permission.sh"
}
teardown() { devagent_test_teardown; }

@test "permission_gate: missing project or gate → rc 2" {
    run permission_gate "" push_mr
    [ "$status" -eq 2 ]
    run permission_gate "$TEST_PROJECT" ""
    [ "$status" -eq 2 ]
}

@test "permission_gate: gate true → rc 0, silent" {
    # fixture config sets permissions.push_mr = true
    run permission_gate "$TEST_PROJECT" push_mr "PLAN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "permission_gate: absent permissions key defaults to DENY (non-tty dies)" {
    # LOAD-BEARING: the key must be ABSENT, not explicit-false. config_get returns
    # a literal "false" for an explicit key, so the `|| echo false` default-deny
    # fallback only fires when the key is missing — that fallback is what the AC
    # pins. Gating on an explicit-false key would pass even with the default
    # flipped to allow, silently defeating the pin (#336 improve, Ambiguity 1).
    devagent_config_unset "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.permissions.push_mr"
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/paths.sh'; . '$DEVAGENT_ROOT/scripts/lib/io.sh'; \
        . '$DEVAGENT_ROOT/scripts/lib/config.sh'; . '$DEVAGENT_ROOT/scripts/lib/permission.sh'; \
        permission_gate '$TEST_PROJECT' push_mr 'PLAN TEXT' </dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PLAN TEXT"* ]]          # plan emitted to stderr
    [[ "$output" == *"denied"* ]]             # died on default-deny
}

@test "permission_gate: DA_YES=1 bypasses a denied gate" {
    # DA_YES bypasses every gate uniformly (no push_mr special-casing in
    # permission_gate — #336 improve, Ambiguity 2). commit_devdoc=false → denied
    # without DA_YES; DA_YES=1 makes confirm() return 0 → gate passes.
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.permissions.commit_devdoc" false
    # Self-pinning (#336 redmr): first prove it DENIES without DA_YES, so the
    # rc-0 below is attributable to the bypass, not to the gate allowing anyway.
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/paths.sh'; . '$DEVAGENT_ROOT/scripts/lib/io.sh'; \
        . '$DEVAGENT_ROOT/scripts/lib/config.sh'; . '$DEVAGENT_ROOT/scripts/lib/permission.sh'; \
        permission_gate '$TEST_PROJECT' commit_devdoc 'PLAN' </dev/null"
    [ "$status" -ne 0 ]
    DA_YES=1 run permission_gate "$TEST_PROJECT" commit_devdoc "PLAN"
    [ "$status" -eq 0 ]
}
