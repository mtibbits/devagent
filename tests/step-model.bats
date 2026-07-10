#!/usr/bin/env bats
# #151: CLI face of step_models_tier so checking-class skills can resolve
# their dispatch model override without sourcing the bash lib chain.
bats_require_minimum_version 1.5.0
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

@test "step-model.sh resolves checking tier for preship (21) (#149)" {
    _add_step_models 'checking = "fable"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 21
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

# ---- #291: per-issue marker (.devagent-step-models) ----------------------

_marker() { printf '%s' "$1" > "$DEVDOC_DIR/Issue-1/.devagent-step-models"; }

@test "per-issue marker beats the project checking tier (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
    [[ "$stderr" == *"per-issue"* ]]
    [[ "$stderr" == *"$DEVDOC_DIR/Issue-1/.devagent-step-models"* ]]
}

@test "per-issue marker beats a per-step numeric key (#291)" {
    _add_step_models 'checking = "opus"
"14" = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "per-issue marker fires for preship (21) (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 21
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "per-issue marker 'inherit' forces session-model inheritance (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'inherit'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"inherit"* ]]
}

@test "per-issue marker does NOT apply to a non-checking step (#291)" {
    _add_step_models 'thinking = "sonnet"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 7
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet" ]
    [ -z "$stderr" ]
}

@test "whitespace-only per-issue marker fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    _marker '   '
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"$DEVDOC_DIR/Issue-1/.devagent-step-models"* ]]
}

@test "multi-token / invalid-charset per-issue marker fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable opus'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *".devagent-step-models"* ]]
}

@test "explicit third CLI arg beats the state-derived issue dir (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    other="$DEVAGENT_TMP/other-issue"
    mkdir -p "$other"
    printf 'haiku' > "$other/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14 "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "haiku" ]
}

@test "cleared active_issue suppresses the stale marker (S2 guard) (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    # cleanup clears active_issue but NOT issue_dir — the leftover marker
    # must not steer post-cleanup runs.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue ""
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
    [ -z "$stderr" ]
}

@test "legacy 'null' active_issue suppresses the stale marker too (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue "null"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
}

@test "exists-but-unreadable marker fails loud, not silent fallback (#291)" {
    if [ "$(id -u)" -eq 0 ]; then skip "root reads anything"; fi
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    chmod 000 "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not readable"* ]]
}

@test "marker that is a directory fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    mkdir -p "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 14
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not a regular file"* ]]
}
