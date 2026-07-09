#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "fix/1-x"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "HEAD"
    mkdir -p "$DEVAGENT_TMP/fake-scripts"
    cat > "$DEVAGENT_TMP/fake-scripts/analyze-static.sh" <<EOF
#!/usr/bin/env bash
echo "static \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    cat > "$DEVAGENT_TMP/fake-scripts/analyze-sanitizers.sh" <<EOF
#!/usr/bin/env bash
echo "san \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-scripts/"*.sh
    export DEVAGENT_ANALYZE_STATIC="$DEVAGENT_TMP/fake-scripts/analyze-static.sh"
    export DEVAGENT_ANALYZE_SANITIZERS="$DEVAGENT_TMP/fake-scripts/analyze-sanitizers.sh"
}
teardown() { devagent_test_teardown; }

@test "analyze.sh runs static then sanitizers and marks step 11 done" {
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    static_line=$(grep -n '^static ' "$DEVAGENT_STUB_LOG" | head -1 | cut -d: -f1)
    san_line=$(grep -n '^san '    "$DEVAGENT_STUB_LOG" | head -1 | cut -d: -f1)
    [ "$static_line" -lt "$san_line" ]
    grep -qE '^- \[x\] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'analyze: static + sanitizers complete' "$DEVDOC_DIR/Issue-1/checklist.md"
}

# ---- #55: analyze knob dispatch --------------------------------------------

_set_analyze() {  # $1 = knob value; inserted INSIDE [project.X] (an append would
                  # land in [..issue_workflow] and silently test the cmake path)
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.analyze" "$1"
}

_stub_shellcheck_analyzer() {
    printf '#!/usr/bin/env bash\necho "shellcheck $*" >> "%s"\n' "$DEVAGENT_STUB_LOG" \
        > "$DEVAGENT_TMP/fake-scripts/analyze-shellcheck.sh"
    chmod +x "$DEVAGENT_TMP/fake-scripts/analyze-shellcheck.sh"
    export DEVAGENT_ANALYZE_SHELLCHECK="$DEVAGENT_TMP/fake-scripts/analyze-shellcheck.sh"
}

@test "analyze = shellcheck runs the shellcheck analyzer, not static/sanitizers (#55)" {
    _set_analyze shellcheck
    _stub_shellcheck_analyzer
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^shellcheck ' "$DEVAGENT_STUB_LOG"
    run grep -E '^(static|san) ' "$DEVAGENT_STUB_LOG"
    [ "$status" -ne 0 ]
    grep -qE '^- \[x\] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'analyze: shellcheck' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "analyze = shellcheck execs the REAL analyzer (no bash/stub crutch) (#55 preship)" {
    # Pins the committed exec bit: the dispatch runs the script directly, so a
    # 100644 mode dies with exit 126 — invisible to every `bash ...` invocation.
    _set_analyze shellcheck
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-shellcheck.txt" ]
    grep -qE '^- \[x\] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "analyze = none self-marks step 11 [-] with a logged reason (#55)" {
    _set_analyze none
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    if [ -f "$DEVAGENT_STUB_LOG" ]; then
        run grep -E '^(static|san|shellcheck) ' "$DEVAGENT_STUB_LOG"
        [ "$status" -ne 0 ]
    fi
    grep -qE '^- \[-\] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'analyze: skipped' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q '^last_step[[:space:]]*=[[:space:]]*"11"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "unknown analyze value dies naming the legal values, step unmarked (#55)" {
    _set_analyze cppchek
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"cmake"* && "$output" == *"shellcheck"* && "$output" == *"none"* ]]
    grep -qE '^- \[ \] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    if [ -f "$DEVAGENT_STUB_LOG" ]; then
        run grep -E '^(static|san) ' "$DEVAGENT_STUB_LOG"
        [ "$status" -ne 0 ]
    fi
}

@test "analyze = \"\" (empty) behaves as cmake (#55)" {
    _set_analyze ""
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^static ' "$DEVAGENT_STUB_LOG"
    grep -q '^san ' "$DEVAGENT_STUB_LOG"
    grep -q 'analyze: static + sanitizers complete' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "a failing sanitizer leg leaves step 11 UNMARKED through analyze.sh (#117 e2e)" {
    # End-to-end through the REAL sanitizers script (no fake crutch): a ctest
    # failure must exit analyze.sh nonzero BEFORE the state write / step-11
    # mark / completion log — so an --auto chain (next.sh set -e) halts.
    touch "$SOURCE_DIR/CMakeLists.txt"                 # pass the loud-skip guard
    export DEVAGENT_ANALYZE_SANITIZERS="$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh"
    devagent_stub cmake ""                             # configure + build succeed
    devagent_stub ctest "FAIL: 1/2" 1                  # ctest fails every leg
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"ctest exit=1"* ]]
    [[ "$output" == *"$DEVDOC_DIR/Issue-1/analysis/"* ]]
    # Step 11 stays [ ]; no completion log; state's last_step never advanced.
    grep -qE '^- \[ \] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    run grep -q 'analyze: static + sanitizers complete' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
    grep -qE '^last_step[[:space:]]*=[[:space:]]*5$' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "an unresolvable baseline leaves step 11 UNMARKED through analyze.sh (#314 e2e)" {
    # analyze = shellcheck + the REAL analyzer + a bad baseline: analyze.sh must
    # exit nonzero BEFORE the step-11 mark / state write (so an --auto chain
    # halts), not mark step 11 [x] on a vacuous empty scope.
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    _set_analyze shellcheck
    export DEVAGENT_ANALYZE_SHELLCHECK="$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "no-such-baseline-ref-314"
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"unresolvable"* ]]     # die-only fragment (#314 review)
    # Step 11 stays [ ]; completion log absent; last_step never advanced past 5.
    grep -qE '^- \[ \] +11\. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    run grep -q 'shellcheck (diff-scoped) complete' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
    grep -qE '^last_step[[:space:]]*=[[:space:]]*5$' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
