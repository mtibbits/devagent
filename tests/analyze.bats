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
