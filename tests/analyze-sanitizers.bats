#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    export DEVAGENT_DATE_OVERRIDE=1999-01-02   # #338: freeze the analyze date
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x \
      && touch CMakeLists.txt \
      && echo a > a.cc && git add a.cc \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m base )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "fix/1-x"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "HEAD~0"
    devagent_stub cmake ""
    devagent_stub ctest "PASS: 2/2"
}
teardown() { devagent_test_teardown; }

@test "analyze-sanitizers.sh runs three sanitizer profiles and writes one file each" {
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-ubsan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-tsan.txt" ]
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=address' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=undefined' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=thread' "$DEVAGENT_STUB_LOG"
}

@test "a failing ctest leg FAILS the step, naming every leg + its artifact (#117)" {
    devagent_stub ctest "FAIL: 1/2" 1
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    # Artifact still records the ctest output + its exit line (evidence).
    grep -q "FAIL: 1/2" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
    grep -q "exit=1" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
    # One ctest stub serves every leg → all three fail; the die names each.
    [[ "$output" == *"asan (ctest exit=1)"* ]]
    [[ "$output" == *"ubsan (ctest exit=1)"* ]]
    [[ "$output" == *"tsan (ctest exit=1)"* ]]
    [[ "$output" == *"$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"* ]]
}

@test "a configure failure FAILS the step and skips build+ctest (#117)" {
    devagent_stub cmake "" 1
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"configure exit=1"* ]]
    grep -q "configure failed" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
    # build + ctest never ran for any leg (configure short-circuits the leg).
    devagent_refute_logged '--build'
    devagent_refute_logged '--output-on-failure'
}

@test "a build failure FAILS the step and skips ctest (#117)" {
    # cmake succeeds on configure (-S/-B) but fails on --build.
    cat > "$DEVAGENT_STUB_BIN/cmake" <<'STUB'
#!/usr/bin/env bash
{ printf 'cmake'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$DEVAGENT_STUB_LOG"
for a in "$@"; do [ "$a" = "--build" ] && exit 1; done
exit 0
STUB
    chmod +x "$DEVAGENT_STUB_BIN/cmake"
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"build exit=1"* ]]
    grep -q "ctest skipped: build failed" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
    devagent_refute_logged '--output-on-failure'
}

@test "a single failing leg names ONLY that leg (#117)" {
    # ctest fails only inside the tsan build dir; asan/ubsan pass. Build dirs are
    # keyed per project+issue now (#351: build-<key>-tsan), so match the -tsan suffix.
    cat > "$DEVAGENT_STUB_BIN/ctest" <<'STUB'
#!/usr/bin/env bash
case "$PWD" in *-tsan*) exit 1 ;; esac
exit 0
STUB
    chmod +x "$DEVAGENT_STUB_BIN/ctest"
    # pass-through setarch so the tsan leg's ctest actually runs (in build-tsan).
    cat > "$DEVAGENT_STUB_BIN/setarch" <<'STUB'
#!/usr/bin/env bash
shift                                          # drop <arch>
while [ "${1:0:2}" = "--" ]; do shift; done    # drop leading --options
exec "$@"
STUB
    chmod +x "$DEVAGENT_STUB_BIN/setarch"
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"tsan (ctest exit=1)"* ]]
    [[ "$output" != *"asan ("* ]]
    [[ "$output" != *"ubsan ("* ]]
    grep -q "exit=0" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
    grep -q "exit=1" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-tsan.txt"
}

@test "non-CMake source LOUD-skips the sanitizer legs, exit 0 (#117 loud-skip)" {
    rm -f "$SOURCE_DIR/CMakeLists.txt"
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # Loud (warn to stderr), naming the source dir and the #55 fix — NOT silent.
    [[ "$output" == *"$SOURCE_DIR"* ]]
    [[ "$output" == *"CMakeLists.txt"* ]]
    [[ "$output" == *"analyze ="* ]]
    # No sanitizer build was attempted.
    devagent_refute_logged 'fsanitize'
    [ ! -f "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt" ]
}

@test "tsan tag wraps BOTH cmake --build and ctest in setarch; asan/ubsan do not (#32)" {
    devagent_stub setarch ""
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # ASLR disabled for the build-time gtest_discover_tests exec (#32) ...
    grep -qE "^setarch .* --addr-no-randomize .* --build .*-tsan" "$DEVAGENT_STUB_LOG"
    # ... and for the ctest run (#1).
    grep -qE "^setarch .* --addr-no-randomize .* --output-on-failure" "$DEVAGENT_STUB_LOG"
    # setarch invoked exactly twice — both phases of the tsan tag; asan/ubsan never use it.
    [ "$(grep -c '^setarch ' "$DEVAGENT_STUB_LOG")" -eq 2 ]
}

@test "a never-returning ctest is killed at the budget and FAILS the step (#351/#117)" {
    # A hung ctest with no timeout would wedge an --auto chain forever. With the
    # budget wrap it is killed at DEVAGENT_ANALYZE_TIMEOUT and the leg fails.
    # `exec sleep` so timeout(1)'s signal reaches the sleep directly (clean kill).
    cat > "$DEVAGENT_STUB_BIN/ctest" <<'STUB'
#!/usr/bin/env bash
echo "ctest $*" >> "$DEVAGENT_STUB_LOG"
exec sleep 300
STUB
    chmod +x "$DEVAGENT_STUB_BIN/ctest"
    # Budget 1s: the three legs each time out fast — the run must NOT hang.
    DEVAGENT_ANALYZE_TIMEOUT=1 run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]                                  # step 11 stays [ ] (#117: die)
    [[ "$output" == *"timed out"* ]]                     # labeled as a timeout, not a bare exit
    [[ "$output" == *"ctest timed out >1s"* ]]
    # ctest received the per-test --timeout too (belt-and-suspenders).
    grep -q "ctest --timeout 1 --output-on-failure" "$DEVAGENT_STUB_LOG"
    # The artifact records the timeout for a later reader.
    grep -qi "timed out\|ctest" "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-asan.txt"
}

@test "build dirs are keyed per project+issue so concurrent chains don't collide (#351)" {
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # The three legs live under project+issue-keyed dirs (not the shared build-<tag>).
    ls -d "$SOURCE_DIR"/build-*-Issue-1-asan  >/dev/null
    ls -d "$SOURCE_DIR"/build-*-Issue-1-ubsan >/dev/null
    ls -d "$SOURCE_DIR"/build-*-Issue-1-tsan  >/dev/null
    # The old un-keyed names are NOT used (a concurrent Issue-2 would key to its own).
    [ ! -d "$SOURCE_DIR/build-asan" ]
    [ ! -d "$SOURCE_DIR/build-tsan" ]
}
