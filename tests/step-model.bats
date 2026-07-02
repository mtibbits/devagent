#!/usr/bin/env bats
# #151: CLI face of step_models_tier so checking-class skills can resolve
# their dispatch model override without sourcing the bash lib chain.
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

_add_step_models() {  # $1 = TOML lines for the table body
    printf '[project.%s.step_models]\n%s\n' "$TEST_PROJECT" "$1" \
        >> "$HOME/.claude/devagent/config.toml"
}

@test "step-model.sh resolves the checking class tier for step 14 (#151)" {
    _add_step_models 'checking = "fable"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "step-model.sh per-step override beats the class tier (#151)" {
    _add_step_models 'checking = "fable"
"14" = "opus"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
}

@test "step-model.sh exits 1 printing nothing when no table configured (#151)" {
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
