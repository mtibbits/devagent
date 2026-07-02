#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
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
    sed -i "/^\[project.$TEST_PROJECT\]/a analyze = \"$1\"" \
        "$HOME/.claude/devagent/config.toml"
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
