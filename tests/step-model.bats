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

@test "step-model.sh resolves the checking class tier for step 16 (#151)" {
    _add_step_models 'checking = "fable"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "step-model.sh per-step override beats the class tier (#151)" {
    _add_step_models 'checking = "fable"
"16" = "opus"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
}

@test "step-model.sh exits nonzero printing nothing when no table configured (#151)" {
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "step-model.sh resolves checking tier for preship (17) (#149)" {
    _add_step_models 'checking = "fable"'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 17
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

# ---- #291: per-issue marker (.devagent-step-models) ----------------------

_marker() { printf '%s' "$1" > "$DEVDOC_DIR/Issue-1/.devagent-step-models"; }

@test "per-issue marker beats the project checking tier (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
    [[ "$stderr" == *"per-issue"* ]]
    [[ "$stderr" == *"$DEVDOC_DIR/Issue-1/.devagent-step-models"* ]]
}

@test "per-issue marker beats a per-step numeric key (#291)" {
    _add_step_models 'checking = "opus"
"16" = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "per-issue marker fires for preship (17) (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 17
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
}

@test "per-issue marker 'inherit' forces session-model inheritance (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'inherit'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"inherit"* ]]
}

# Title tightened by #561: still true, but only of the BARE form. A KEYED marker
# (`thinking: <tok>`) DOES apply to thinking steps — see the #561 cases below.
# Register: Issue-321, re-read unchanged neighbours for a newly-created
# contradiction.
@test "BARE per-issue marker does NOT apply to a non-checking step (#291)" {
    _add_step_models 'thinking = "sonnet"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 9
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet" ]
    [ -z "$stderr" ]
}

@test "whitespace-only per-issue marker fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    _marker '   '
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"$DEVDOC_DIR/Issue-1/.devagent-step-models"* ]]
}

@test "multi-token / invalid-charset per-issue marker fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable opus'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
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
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16 "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "haiku" ]
}

@test "cleared active_issue suppresses the stale marker (S2 guard) (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    # cleanup clears active_issue but NOT issue_dir — the leftover marker
    # must not steer post-cleanup runs.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue ""
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
    [ -z "$stderr" ]
}

@test "legacy 'null' active_issue suppresses the stale marker too (#291)" {
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue "null"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]
}

@test "exists-but-unreadable marker fails loud, not silent fallback (#291)" {
    if [ "$(id -u)" -eq 0 ]; then skip "root reads anything"; fi
    _add_step_models 'checking = "opus"'
    _marker 'fable'
    chmod 000 "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not readable"* ]]
}

@test "marker that is a directory fails loud (#291)" {
    _add_step_models 'checking = "opus"'
    mkdir -p "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not a regular file"* ]]
}

@test "step-model: the three no-tier states have distinct exit codes (#458)" {
    # #458 makes an unresolved tier mean "agent default" for the agent-bound
    # steps, so "no tier configured" and the reserved 'inherit' marker — which
    # were interchangeable while both meant inherit — now mean OPPOSITE things.
    # They are discriminated by exit code, not by stderr prose a caller must
    # parse. Collapsing 2 into 3 silently defeats the only escape from a pinned
    # tier; this is the test that catches that.
    _add_step_models 'checking = "opus"'
    local d="$DEVDOC_DIR/Issue-1"

    # rc 0: a tier resolves.
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 17 "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]

    # rc 2: the operator's explicit inherit escape — empty stdout, but NOT rc 3.
    printf 'inherit' > "$d/.devagent-step-models"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 17 "$d"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"per-issue"* ]]
    rm -f "$d/.devagent-step-models"

    # rc 1: a bad marker is an error, never an inherit.
    printf 'two tokens' > "$d/.devagent-step-models"
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 17 "$d"
    [ "$status" -eq 1 ]
    rm -f "$d/.devagent-step-models"
}

@test "step-model: rc 3 is 'nothing configured', distinct from the inherit escape (#458)" {
    # No step_models table at all — the fresh-install state that takes the
    # agent default for steps 5/16/17 (#527 added improve).
    local d="$DEVDOC_DIR/Issue-1"
    local step
    for step in 5 16 17; do
        run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" "$step" "$d"
        [ "$status" -eq 3 ]
        [ -z "$output" ]
    done
}

@test "step-model: callers whose fallback IS inherit still collapse every nonzero (#458)" {
    # Backward compatibility: step 15 and next.sh/catchup.sh use
    # `$(... || true)` or `if tier=$(...)`, for which rc 2 and rc 3 are both
    # correctly empty. Adding exit codes must not change what they see.
    local d="$DEVDOC_DIR/Issue-1"
    printf 'inherit' > "$d/.devagent-step-models"
    run bash -c '"$1"/scripts/step-model.sh "$2" 5 "$3" 2>/dev/null || true' _ \
        "$DEVAGENT_ROOT" "$TEST_PROJECT" "$d"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -f "$d/.devagent-step-models"
}

@test "step-model: a config-table tier of 'inherit' is the same escape as the marker (#458 r2)" {
    # Without this, checking = "inherit" resolved rc 0 with stdout 'inherit',
    # and the bound-step wrappers would dispatch the Agent tool with
    # model: inherit — a value the tool's closed enum rejects (hard crash on a
    # config any operator could reasonably write). Symmetric semantics: rc 2,
    # empty stdout, a provenance note WITHOUT the word 'per-issue' so callers
    # can distinguish the stamp form.
    _add_step_models 'checking = "inherit"'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"config tier"* ]]
    [[ "$stderr" != *"per-issue"* ]]
}

# ---- #561: KEYED per-issue marker (checking: / thinking:), both classes ----

@test "keyed marker steers BOTH classes; default class still ignores it (#561)" {
    _add_step_models 'checking = "opus"
thinking = "haiku"'
    _marker 'checking: fable
thinking: sonnet'
    # checking class -> the marker's checking value, with per-issue provenance
    for step in 5 15 16 17; do
        run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" "$step"
        [ "$status" -eq 0 ]
        [ "$output" = "fable" ]
        [[ "$stderr" == *"per-issue"* ]]
        [[ "$stderr" == *".devagent-step-models"* ]]
    done
    # thinking class -> the marker's thinking value
    for step in 2 9 10 11 14; do
        run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" "$step"
        [ "$status" -eq 0 ]
        [ "$output" = "sonnet" ]
        [[ "$stderr" == *"per-issue"* ]]
    done
    # default class (12 commit) never reads the marker in either form
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 12
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "keyed marker with only one class leaves the other on the config chain (#561)" {
    _add_step_models 'thinking = "sonnet"'
    _marker 'checking: fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 5
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
    # step 9 falls THROUGH to the table — not a die, not the checking value
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 9
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet" ]
    [ -z "$stderr" ]
}

@test "keyed 'inherit' returns rc 2 per class, re-pinning #291 under the new form (#561)" {
    _add_step_models 'checking = "opus"
thinking = "opus"'
    _marker 'thinking: inherit'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 2
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"per-issue"* ]]
    [[ "$stderr" == *"inherit"* ]]
    _marker 'checking: inherit'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"per-issue"* ]]
}

@test "malformed keyed marker dies naming the marker — never a silent fallback (#561)" {
    # NOTE: each of these also dies at baseline, but for the WRONG reason (the
    # bare-form parser sees a multi-token blob). What makes them non-vacuous is
    # the paired 'indented line is keyed' case below plus the rc-2/rc-0 cases
    # above: together they prove the keyed parser, not the bare one, is running.
    _add_step_models 'checking = "opus"'
    # empty value
    _marker 'checking:'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
    [[ "$stderr" == *".devagent-step-models"* ]]
    # multi-token value
    _marker 'checking: a b'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
    [[ "$stderr" == *".devagent-step-models"* ]]
    # a line that is neither blank nor a class key
    _marker 'checking: fable
default: opus'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"default: opus"* ]]
    # DUPLICATE lines for the same class die naming BOTH values — fail closed on
    # ambiguous authored intent, deliberately the opposite of flags_get's
    # first-match-wins (the marker is local operator state, not remote content)
    _marker 'checking: fable
checking: opus'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"duplicate"* ]]
    [[ "$stderr" == *"fable"* ]]
    [[ "$stderr" == *"opus"* ]]
}

@test "one regex governs detector AND validator: an indented line is keyed (#561)" {
    # Guards the round-1 bug where a permissive detector and a strict validator
    # disagreed, making '  checking: fable' keyed by one rule and malformed by
    # the other. Red at baseline (the bare parser rejects it as multi-token).
    _add_step_models 'checking = "opus"'
    _marker '  checking: fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
    [[ "$stderr" == *"per-issue"* ]]
}

@test "#561 U3 delta: an unreadable marker now dies for THINKING steps too" {
    # Deliberate behavior change, asserted so it can never regress silently: the
    # structural check (exists but is not a regular file) applies to both classes
    # because 'the operator left something unreadable here' is a fault whichever
    # step asks. Previously a thinking step fell through to the config chain.
    _add_step_models 'thinking = "sonnet"
checking = "opus"'
    rm -f "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    mkdir -p "$DEVDOC_DIR/Issue-1/.devagent-step-models"
    for step in 9 16; do
        run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" "$step"
        [ "$status" -eq 1 ]
        [[ "$stderr" == *"not a regular file"* ]]
    done
    # the default class is untouched by the delta
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 12
    [ "$status" -ne 0 ]
    [ -z "$stderr" ]
}

@test "#561 AC11: a bare-token marker keeps EXACT legacy semantics" {
    # Equivalence by construction (register: Issue-94) — config.sh's bare-token
    # branch is textually untouched. This case is GREEN AT BASELINE by design and
    # is a PIN, not a born-red claim; it exists so the keyed rewrite cannot
    # regress the legacy form.
    _add_step_models 'thinking = "sonnet"
checking = "opus"'
    _marker 'fable'
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 0 ]
    [ "$output" = "fable" ]
    # checking-class ONLY: a thinking step resolves the table, stderr SILENT
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 9
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet" ]
    [ -z "$stderr" ]
    # reserved token, empty, and multi-token all keep their shipped behavior
    _marker 'inherit'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 2 ]
    _marker '   '
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
    _marker 'fable opus'
    run "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
    [ "$status" -eq 1 ]
}

@test "#561: the ADVISORY hint path surfaces a keyed thinking tier (next/catchup)" {
  # scripts/next.sh:136 and scripts/catchup.sh:75 both call
  # step_models_tier "$project" "$cur" "$issue_dir" for the CURRENT step. For the
  # inline thinking steps (9/10/11/14) that hint is the ONLY place the tier
  # appears, since a session cannot swap its own model — so it is the whole
  # enforcement surface for implementation-model there and is pinned here.
  _add_step_models 'thinking = "opus"'
  _marker 'thinking: sonnet
checking: fable'
  for step in 9 10 11 14; do
    run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" "$step"
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet" ]   # the marker beats the project thinking pin
  done
}

@test "#561: a malformed marker is LOUD on the advisory path, not silently dropped" {
  # Decision recorded: next/catchup guard the call as `if _tier="$(…)"`, which
  # swallows the rc but NOT the stderr. A malformed marker therefore prints its
  # die message on every next/catchup while the flow continues. That is the
  # intended behavior — the alternative (silencing stderr) would hide a broken
  # marker from the operator at exactly the moment they are looking at the step
  # list, and pull.sh's write-time validation means a malformed marker can only
  # arrive by hand-edit.
  _add_step_models 'thinking = "opus"'
  _marker 'checking: a b'
  run --separate-stderr "$DEVAGENT_ROOT/scripts/step-model.sh" "$TEST_PROJECT" 16
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"exactly one token"* ]]
}
