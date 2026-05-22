#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    cat > "$DEVAGENT_STUB_BIN/fake-python" <<EOF
#!/usr/bin/env bash
printf 'python' >> "$DEVAGENT_STUB_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$DEVAGENT_STUB_LOG"; done
printf '\n' >> "$DEVAGENT_STUB_LOG"
echo "cppcheck: clean"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/fake-python"
    export DEVAGENT_PYTHON="$DEVAGENT_STUB_BIN/fake-python"
}
teardown() { devagent_test_teardown; }

@test "analyze-static.sh invokes static_analysis_diff.py with baseline + build dir" {
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "$DEVAGENT_ROOT/static_analysis_diff.py HEAD"
    out_file="$(ls "$DEVDOC_DIR/Issue-1/analysis"/*-static.txt | head -1)"
    [ -s "$out_file" ]
    grep -q "cppcheck: clean" "$out_file"
}
