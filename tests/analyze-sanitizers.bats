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

@test "sanitizers: a corrupt compiler ID still stamps printable ASCII at line 2 (#676)" {
    _require_posix_python
    _asan_fixture
    sed -i 's/"GNU"/"GN\xffU"/' "$fixture_compiler_file"
    [ "$(tr -cd '\377' < "$fixture_compiler_file" | wc -c)" -eq 1 ]   # control: the byte is planted
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "$(_san_artifact asan)")" = "analyzer: asan GNU 99.1.0 (C)" ]
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
    [ -z "$(compgen -G "$dir/.stamp-*" || true)" ]   # no temp left behind
    local asan; asan="$(_san_artifact asan)"
    grep -q 'exit=0' "$asan"
    run grep -c '^analyzer:' "$asan"
    [ "$status" -eq 1 ]
}

# Whitespace-normalised fixed-string match, so a reflow cannot split a token.
_doc_has() { tr -s '[:space:]' ' ' < "$1" | grep -qF -- "$2"; }

@test "docs: analyze.md and both cmake-family headers record the stamp policy (#676)" {
    local md="$DEVAGENT_ROOT/commands/analyze.md"
    _doc_has "$md" '`analyzer: <row> <version>`'
    _doc_has "$md" '`analyzer: <tag> <compiler identity>`'
    _doc_has "$md" '`analyzer: shellcheck <version>`'
    _doc_has "$DEVAGENT_ROOT/static_analysis_diff.py" 'stamp, do not change what runs'
    _doc_has "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" 'stamp, do not change what runs'
}

# A bin dir of commands that fail, put on PATH for one run only (teardown keeps
# the real rm). Each named command exits 1 with no output.
_failing_bin() {
    local d="$DEVAGENT_TMP/failbin" c
    mkdir -p "$d"
    for c in "$@"; do printf '#!/bin/sh\nexit 1\n' > "$d/$c"; chmod +x "$d/$c"; done
    printf '%s' "$d"
}

@test "sanitizers: a failed head in the line-2 rewrite keeps the artifact as written (#676)" {
    local fb; fb="$(_failing_bin head)"
    PATH="$fb:$PATH" run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$DEVAGENT_TMP/out.txt"
    [ "$(grep -c 'could not write the analyzer line' "$DEVAGENT_TMP/out.txt")" -eq 3 ]
    local tag f
    for tag in asan ubsan tsan; do
        f="$(_san_artifact "$tag")"
        [ "$(sed -n 1p "$f")" = "=== $tag ===" ]
        run grep -c '^analyzer:' "$f"
        [ "$status" -eq 1 ]
    done
}

@test "sanitizers: a failing rm in the rewrite's failure arm never aborts the legs (#676)" {
    local fb; fb="$(_failing_bin mv rm)"
    PATH="$fb:$PATH" run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$DEVAGENT_TMP/out.txt"
    [ "$(grep -c 'could not write the analyzer line' "$DEVAGENT_TMP/out.txt")" -eq 3 ]
    local tag
    for tag in asan ubsan tsan; do
        grep -q 'exit=0' "$(_san_artifact "$tag")"
    done
}

# --- #932: every leg runs under libexec/long-run.sh, in the stream shape it had ---
#
# Configure and build wrote `2>&1` into the artifact and now pass --merge; ctest
# kept its stderr out of the artifact and still does (two streams). Each leg
# declares the silent window resolved ONCE, before any leg: analyze_silent_secs,
# or min(the analyze timeout, watchdog_silent_max_secs) when that key is unset.
# The window tests read the window file the wrapper holds open WHILE a stub
# runs, so they assert what `watchdog.sh check` would read, not an argv.
SAN_ID=0f8fad5b-d9cb-469f-a165-70867728950e
_san_cfg()  { printf '%s' "$HOME/.claude/devagent/config.toml"; }
_san_wd()   { printf '%s' "$HOME/.claude/devagent/state/watchdog"; }
_san_unattended() {
    run env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$SAN_ID" "$@" \
        "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
}
# cmake and ctest stubs that append the live window (one line per call) to
# $DEVAGENT_TMP/seen-window; no window open reads as `none`.
_san_window_stubs() {
    local cmd
    export SAN_WD_DIR; SAN_WD_DIR="$(_san_wd)/$SAN_ID"
    for cmd in cmake ctest; do
        printf '%s\n' '#!/usr/bin/env bash' \
            "echo \"$cmd \$*\" >> \"\$DEVAGENT_STUB_LOG\"" \
            'cat "$SAN_WD_DIR"/wrap.*.window >> "$DEVAGENT_TMP/seen-window" 2>/dev/null || echo none >> "$DEVAGENT_TMP/seen-window"' \
            > "$DEVAGENT_STUB_BIN/$cmd"
        chmod +x "$DEVAGENT_STUB_BIN/$cmd"
    done
}
# 9 = three legs x (configure, build, ctest), every one under the same window.
_san_windows_all() {
    [ "$(wc -l < "$DEVAGENT_TMP/seen-window")" -eq 9 ]
    [ "$(sort -u "$DEVAGENT_TMP/seen-window")" = "$1" ]
}

@test "attended sanitizer artifacts are unchanged (#932)" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo c-out' 'echo c-err >&2' > "$DEVAGENT_STUB_BIN/cmake"
    printf '%s\n' '#!/usr/bin/env bash' 'echo t-out' 'echo t-err >&2' > "$DEVAGENT_STUB_BIN/ctest"
    chmod +x "$DEVAGENT_STUB_BIN/cmake" "$DEVAGENT_STUB_BIN/ctest"
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # The artifact, whole: configure and build merged (stdout then stderr, the
    # stub's own order), ctest's stdout only.
    local tag
    for tag in asan ubsan tsan; do
        printf '%s\n' "=== $tag ===" "analyzer: $tag (version unknown)" \
            c-out c-err c-out c-err t-out exit=0 > "$DEVAGENT_TMP/want.txt"
        diff "$DEVAGENT_TMP/want.txt" "$(_san_artifact "$tag")"
    done
    # ctest's stderr reaches the caller, once per leg, and nothing else does.
    [ "$output" = "$(printf 't-err\nt-err\nt-err')" ]
    # Attended: no session directory; the wrapper's logs are the only trace.
    [ -z "$(find "$(_san_wd)" -mindepth 1 -maxdepth 1 ! -name logs 2>/dev/null)" ]
    [ "$(find "$(_san_wd)/logs" -name 'no-session.*.log' | wc -l)" -eq 12 ]   # 3 x (1 + 1 + 2)
}

@test "a timed-out analyze leg still records \"timed out >Ns\" under the wrapper (#932)" {
    cat > "$DEVAGENT_STUB_BIN/ctest" <<'STUB'
#!/usr/bin/env bash
echo "ctest $*" >> "$DEVAGENT_STUB_LOG"
exec sleep 300
STUB
    chmod +x "$DEVAGENT_STUB_BIN/ctest"
    _san_unattended DEVAGENT_ANALYZE_TIMEOUT=1
    [ "$status" -ne 0 ]
    [[ "$output" == *"asan (ctest timed out >1s)"* ]]
    [[ "$output" == *"tsan (ctest timed out >1s)"* ]]
    grep -q '^ctest timed out (>1s — killed by timeout(1)); exit=124$' "$(_san_artifact asan)"
    # The run was a watched one: nine wrapped legs, and no window outlives them.
    [ "$(find "$(_san_wd)/$SAN_ID" -name 'wrap.*' ! -name '*.window' | wc -l)" -eq 9 ]
    [ -z "$(find "$(_san_wd)/$SAN_ID" -name '*.window')" ]
}

@test "analyze_silent_secs above the maximum fails before any leg runs (#932)" {
    devagent_config_set_int "$(_san_cfg)" defaults.watchdog_silent_max_secs 60
    devagent_config_set_int "$(_san_cfg)" "project.$TEST_PROJECT.analyze_silent_secs" 61
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    devagent_refute_logged 'cmake'
    devagent_refute_logged 'ctest'
    [ ! -e "$(_san_artifact asan)" ]
    [[ "$output" == *"analyze_silent_secs"* ]]
    [[ "$output" == *"61"* ]]
    [[ "$output" == *"watchdog_silent_max_secs"* ]]
    [[ "$output" == *"60"* ]]
}

@test "analyze_silent_secs equal to a 3590 maximum runs the legs with a 3590 window (#932)" {
    devagent_config_set_int "$(_san_cfg)" defaults.watchdog_silent_max_secs 3590
    devagent_config_set_int "$(_san_cfg)" "project.$TEST_PROJECT.analyze_silent_secs" 3590
    _san_window_stubs
    _san_unattended
    [ "$status" -eq 0 ]
    _san_windows_all 3590
}

@test "unset analyze_silent_secs: the legs declare min(analyze timeout, maximum) (#932)" {
    _san_window_stubs
    _san_unattended                         # the default budget, 1800 s, under the shipped 3600
    [ "$status" -eq 0 ]
    _san_windows_all 1800
}

@test "a malformed analyze_silent_secs warns once and the legs take the derived window (#932)" {
    devagent_config_set "$(_san_cfg)" "project.$TEST_PROJECT.analyze_silent_secs" abc
    _san_window_stubs
    _san_unattended DEVAGENT_ANALYZE_TIMEOUT=50
    [ "$status" -eq 0 ]
    _san_windows_all 50
    printf '%s\n' "$output" > "$DEVAGENT_TMP/out.txt"
    [ "$(grep -c 'analyze_silent_secs' "$DEVAGENT_TMP/out.txt")" -eq 1 ]
    grep -q 'WARNING: .*analyze_silent_secs.*50 s' "$DEVAGENT_TMP/out.txt"
}

@test "an attended run opens no window and creates no session directory (#932)" {
    _san_window_stubs
    run env "CLAUDE_CODE_SESSION_ID=$SAN_ID" "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    _san_windows_all none
    [ ! -e "$(_san_wd)/$SAN_ID" ]
}
