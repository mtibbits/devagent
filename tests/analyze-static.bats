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
    devagent_assert_logged "$DEVAGENT_ROOT/static_analysis_diff.py --repo $SOURCE_DIR"
    devagent_assert_logged "--repo $SOURCE_DIR HEAD"
    out_file="$(ls "$DEVDOC_DIR/Issue-1/analysis"/*-static.txt | head -1)"
    [ -s "$out_file" ]
    grep -q "cppcheck: clean" "$out_file"
}

@test "analyze-static.sh configures build dir for a test-inclusive compile DB when CMakeLists present (#275)" {
    # A CMake project: the static phase must reconfigure the build dir with the two
    # flags so test-only TUs land in compile_commands.json.
    : > "$SOURCE_DIR/CMakeLists.txt"
    devagent_stub cmake
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    # Gate on the captured cmake argv, not the script's exit status (#275).
    devagent_assert_logged "cmake -S $SOURCE_DIR -B"
    devagent_assert_logged "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
    devagent_assert_logged "-DENABLE_TESTING=ON"
}

@test "analyze-static.sh does NOT invoke cmake when no CMakeLists (non-CMake project) (#275)" {
    # The devagent-self path: no CMakeLists.txt → the configure must be skipped clean.
    [ ! -e "$SOURCE_DIR/CMakeLists.txt" ]
    devagent_stub cmake
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    devagent_refute_logged "cmake -S"
}
