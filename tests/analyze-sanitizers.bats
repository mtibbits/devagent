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

# #676: line 2 of each sanitizer artifact names the compiler its build dir recorded.
# The fixture is the asan leg's keyed build dir as CMake 4.2.3 leaves it: a cache
# naming 4.2.3 and a CRLF CMakeCCompiler.cmake whose line 4 (the cached version)
# is planted, so a reader that took it instead of probing would show it.
_asan_fixture() {
    local key; key="$(printf '%s-%s' "$TEST_PROJECT" Issue-1 | tr -c 'A-Za-z0-9' '-')"
    local build="$SOURCE_DIR/build-$key-asan"
    mkdir -p "$build/CMakeFiles/4.2.3" "$DEVAGENT_TMP/cc"
    printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=4\nCMAKE_CACHE_MINOR_VERSION:INTERNAL=2\nCMAKE_CACHE_PATCH_VERSION:INTERNAL=3\n' \
        > "$build/CMakeCache.txt"
    printf 'set(CMAKE_C_COMPILER "%s")\r\nset(CMAKE_C_COMPILER_ARG1 "")\r\nset(CMAKE_C_COMPILER_ID "GNU")\r\nset(CMAKE_C_COMPILER_VERSION "1.2.3-planted")\r\n' \
        "$DEVAGENT_TMP/cc/stubcc" > "$build/CMakeFiles/4.2.3/CMakeCCompiler.cmake"
    printf '#!/bin/sh\necho "stubcc 99.1.0"\n' > "$DEVAGENT_TMP/cc/stubcc"
    chmod +x "$DEVAGENT_TMP/cc/stubcc"
    fixture_compiler_file="$build/CMakeFiles/4.2.3/CMakeCCompiler.cmake"
}

_san_artifact() { printf '%s' "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-$1.txt"; }

# The stub compiler is exec'able by subprocess only under a POSIX python (U6).
_require_posix_python() {
    python3 -c 'import os,sys; sys.exit(os.name != "posix")' \
        || skip "stub compiler is a POSIX script; runs in CI/WSL"
}

@test "sanitizers: line 2 stamps the compiler recorded in the asan build dir (#676)" {
    _require_posix_python
    _asan_fixture
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local asan; asan="$(_san_artifact asan)"
    [ "$(sed -n 1p "$asan")" = "=== asan ===" ]
    [ "$(sed -n 2p "$asan")" = "analyzer: asan GNU 99.1.0 (C)" ]
    [ "$(tr -cd '\r' < "$fixture_compiler_file" | wc -c)" -eq 4 ]   # control: CRLF fixture
    [ "$(sed -n 2p "$asan" | tr -cd '\r' | wc -c)" -eq 0 ]
    run grep -c '1.2.3-planted' "$asan"
    [ "$status" -eq 1 ]
    local tag f
    for tag in ubsan tsan; do
        [ "$(sed -n 2p "$(_san_artifact "$tag")")" = "analyzer: $tag (version unknown)" ]
    done
    for tag in asan ubsan tsan; do
        f="$(_san_artifact "$tag")"
        [ "$(grep -c '^analyzer:' "$f")" -eq 1 ]
    done
    [ "$(ls -A "$DEVDOC_DIR/Issue-1/analysis" | wc -l)" -eq 3 ]
}

@test "sanitizers: a configure-failed leg still carries an analyzer line at line 2 (#676)" {
    _require_posix_python
    devagent_stub cmake "" 1
    _asan_fixture
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"configure exit=1"* ]]
    local asan; asan="$(_san_artifact asan)"
    [ "$(sed -n 2p "$asan")" = "analyzer: asan GNU 99.1.0 (C)" ]
    local tag
    for tag in ubsan tsan; do
        [[ "$(sed -n 2p "$(_san_artifact "$tag")")" =~ ^analyzer:\ (ubsan|tsan)\ \(version\ unknown\)$ ]]
    done
    grep -q "configure failed" "$asan"
}

@test "sanitizers: a failing reader stamps (version unknown) and changes nothing else (#676)" {
    devagent_stub failpy "" 1
    export DEVAGENT_PYTHON="$DEVAGENT_STUB_BIN/failpy"
    _asan_fixture
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local tag
    for tag in asan ubsan tsan; do
        [ "$(sed -n 2p "$(_san_artifact "$tag")")" = "analyzer: $tag (version unknown)" ]
        grep -q 'exit=0' "$(_san_artifact "$tag")"
    done
    local calls; calls="$(grep -c '^failpy ' "$DEVAGENT_STUB_LOG" || true)"
    [ "$calls" -gt 0 ]
    [ "$calls" -eq 3 ]
    printf '%s\n' "$output" > "$DEVAGENT_TMP/out.txt"
    [ "$(grep -c 'compiler-identity reader failed (rc=1)' "$DEVAGENT_TMP/out.txt")" -eq 3 ]
}

@test "sanitizers: a failing reader leaves the failure summary unchanged (#676)" {
    devagent_stub failpy "" 1
    export DEVAGENT_PYTHON="$DEVAGENT_STUB_BIN/failpy"
    devagent_stub ctest "FAIL: 1/2" 1
    _asan_fixture
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"asan (ctest exit=1)"* ]]
    [[ "$output" == *"ubsan (ctest exit=1)"* ]]
    [[ "$output" == *"tsan (ctest exit=1)"* ]]
    [[ "$output" == *"$(_san_artifact asan)"* ]]
    local tag
    for tag in asan ubsan tsan; do
        [ "$(sed -n 2p "$(_san_artifact "$tag")")" = "analyzer: $tag (version unknown)" ]
    done
    [[ "$output" == *"compiler-identity reader failed (rc=1)"* ]]
}

@test "sanitizers: the line-2 rewrite keeps the artifact's file mode (#676)" {
    local probe="$DEVAGENT_TMP/modeprobe"
    : > "$probe"; chmod 600 "$probe"
    [ "$(stat -c %a "$probe")" = "600" ] || skip "chmod is a no-op here (noacl mount)"
    umask 022
    : > "$DEVAGENT_TMP/ctrl"
    local want; want="$(stat -c %a "$DEVAGENT_TMP/ctrl")"
    [ "$want" = "644" ]
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local tag f
    for tag in asan ubsan tsan; do
        f="$(_san_artifact "$tag")"
        [ "$(grep -c '^analyzer:' "$f")" -eq 1 ]   # control: the rewrite happened
        [ "$(stat -c %a "$f")" = "$want" ]
    done
}

@test "sanitizers: a failed line-2 rewrite keeps the artifact and the leg result (#676)" {
    local dir="$DEVDOC_DIR/Issue-1/analysis" tag
    mkdir -p "$dir"
    for tag in asan ubsan tsan; do : > "$(_san_artifact "$tag")"; done
    chmod a-w "$dir"
    if touch "$dir/.probe" 2>/dev/null; then
        rm -f "$dir/.probe"; chmod u+w "$dir"
        skip "analysis dir stays writable after chmod a-w (root or noacl)"
    fi
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    chmod u+w "$dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not write the analyzer line"* ]]
    [ "$(ls -A "$dir" | grep -c '^[.]stamp-' || true)" -eq 0 ]   # no temp left behind
    local asan; asan="$(_san_artifact asan)"
    grep -q 'exit=0' "$asan"
    run grep -c '^analyzer:' "$asan"
    [ "$status" -eq 1 ]
}
