#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x \
      && echo a > a.cc && git add a.cc \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m base )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD~0\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    devagent_stub cmake ""
    devagent_stub ctest "PASS: 2/2"
}
teardown() { devagent_test_teardown; }

@test "analyze-sanitizers.sh runs three sanitizer profiles and writes one file each" {
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-ubsan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-tsan.txt" ]
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=address' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=undefined' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=thread' "$DEVAGENT_STUB_LOG"
}

@test "analyze-sanitizers.sh records a non-zero ctest exit in the output" {
    devagent_stub ctest "FAIL: 1/2" 1
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q "FAIL: 1/2" "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt"
    grep -q "exit=1" "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt"
}

@test "tsan tag wraps BOTH cmake --build and ctest in setarch; asan/ubsan do not (#32)" {
    devagent_stub setarch ""
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # ASLR disabled for the build-time gtest_discover_tests exec (#32) ...
    grep -qE "^setarch .* --addr-no-randomize .* --build .*build-tsan" "$DEVAGENT_STUB_LOG"
    # ... and for the ctest run (#1).
    grep -qE "^setarch .* --addr-no-randomize .* --output-on-failure" "$DEVAGENT_STUB_LOG"
    # setarch invoked exactly twice — both phases of the tsan tag; asan/ubsan never use it.
    [ "$(grep -c '^setarch ' "$DEVAGENT_STUB_LOG")" -eq 2 ]
}
