#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "fix/1-x"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "HEAD"
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

@test "analyze-static.sh keys the FALLBACK build dir per project+issue (#351)" {
    # No build_dir configured → the fallback is keyed (not the shared \$source_dir/build),
    # so two concurrent chains on a shared source tree don't collide.
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE "build-[A-Za-z0-9_-]*Issue-1( |$)" "$DEVAGENT_STUB_LOG"
    # the bare un-keyed fallback is NOT used
    devagent_refute_logged " $SOURCE_DIR/build "
}

bats_require_minimum_version 1.5.0   # run --separate-stderr (#932)

# --- #932: both legs run under libexec/long-run.sh, two streams each ---
#
# The configure keeps `>/dev/null` (its stderr still reaches the caller) and the
# analyzer keeps `| tee` (its progress lines stay on stderr). The analyzer gets
# PYTHONUNBUFFERED=1 so its stdout reaches the pipe as it is written.
STATIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e
_static_cfg() { printf '%s' "$HOME/.claude/devagent/config.toml"; }
_static_wd()  { printf '%s' "$HOME/.claude/devagent/state/watchdog"; }
_static_art() { ls "$DEVDOC_DIR/Issue-1/analysis"/*-static.txt; }
# A cmake stub and an analyzer stub that each append `<name> <live window>` to
# $DEVAGENT_TMP/seen-window (`none` when no window is open); the analyzer also
# records PYTHONUNBUFFERED.
_static_window_stubs() {
    export STATIC_WD_DIR; STATIC_WD_DIR="$(_static_wd)/$STATIC_ID"
    : > "$SOURCE_DIR/CMakeLists.txt"
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "cmake $*" >> "$DEVAGENT_STUB_LOG"' \
        'echo "cmake $(cat "$STATIC_WD_DIR"/wrap.*.window 2>/dev/null || echo none)" >> "$DEVAGENT_TMP/seen-window"' \
        > "$DEVAGENT_STUB_BIN/cmake"
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "python $*" >> "$DEVAGENT_STUB_LOG"' \
        'echo "python $(cat "$STATIC_WD_DIR"/wrap.*.window 2>/dev/null || echo none)" >> "$DEVAGENT_TMP/seen-window"' \
        'printf "%s" "${PYTHONUNBUFFERED-<UNSET>}" > "$DEVAGENT_TMP/seen-unbuffered"' \
        'echo "cppcheck: clean"' \
        > "$DEVAGENT_STUB_BIN/fake-python"
    chmod +x "$DEVAGENT_STUB_BIN/cmake" "$DEVAGENT_STUB_BIN/fake-python"
}

@test "attended static artifact is unchanged (#932)" {
    : > "$SOURCE_DIR/CMakeLists.txt"
    printf '%s\n' '#!/usr/bin/env bash' 'echo cfg-out' 'echo cfg-err >&2' > "$DEVAGENT_STUB_BIN/cmake"
    printf '%s\n' '#!/usr/bin/env bash' 'echo progress >&2' 'echo "cppcheck: clean"' 'exit 0' \
        > "$DEVAGENT_STUB_BIN/fake-python"
    chmod +x "$DEVAGENT_STUB_BIN/cmake" "$DEVAGENT_STUB_BIN/fake-python"
    run --separate-stderr "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # stdout and the artifact: the analyzer's stdout alone.
    [ "$output" = "cppcheck: clean" ]
    [ "$(cat "$(_static_art)")" = "cppcheck: clean" ]
    # stderr: the configure's and the analyzer's stderr; the configure's stdout nowhere.
    [ "$stderr" = "$(printf 'cfg-err\nprogress')" ]
    # Attended: no session directory; the wrapper's logs are the only trace.
    [ -z "$(find "$(_static_wd)" -mindepth 1 -maxdepth 1 ! -name logs 2>/dev/null)" ]
    [ "$(find "$(_static_wd)/logs" -name 'no-session.*.log' | wc -l)" -eq 4 ]
}

@test "the analyzer's exit code is the step's, as before (#932)" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo "cppcheck: 1 finding"' 'exit 7' > "$DEVAGENT_STUB_BIN/fake-python"
    chmod +x "$DEVAGENT_STUB_BIN/fake-python"
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 7 ]
    grep -q 'cppcheck: 1 finding' "$(_static_art)"
    [ "$(find "$(_static_wd)/logs" -name 'no-session.*.out.log' | wc -l)" -eq 1 ]
}

@test "an unattended static run declares the window on both legs and unbuffers the analyzer (#932)" {
    devagent_config_set_int "$(_static_cfg)" "project.$TEST_PROJECT.analyze_timeout" 7200
    _static_window_stubs
    run env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$STATIC_ID" \
        "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # Unset analyze_silent_secs: min(7200, the shipped maximum 3600).
    [ "$(cat "$DEVAGENT_TMP/seen-window")" = "$(printf 'cmake 3600\npython 3600')" ]
    [ "$(cat "$DEVAGENT_TMP/seen-unbuffered")" = "1" ]
    [ "$(find "$STATIC_WD_DIR" -name 'wrap.*' ! -name '*.window' | wc -l)" -eq 2 ]
    [ -z "$(find "$STATIC_WD_DIR" -name '*.window')" ]
    grep -q "cppcheck: clean" "$(_static_art)"
}

@test "analyze_silent_secs above the maximum fails before the configure or the analyzer runs (#932)" {
    devagent_config_set_int "$(_static_cfg)" defaults.watchdog_silent_max_secs 60
    devagent_config_set_int "$(_static_cfg)" defaults.analyze_silent_secs 61
    _static_window_stubs
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    devagent_refute_logged 'cmake'
    devagent_refute_logged 'python'
    [ -z "$(ls "$DEVDOC_DIR/Issue-1/analysis")" ]
    [[ "$output" == *"analyze_silent_secs"* ]]
    [[ "$output" == *"61"* ]]
    [[ "$output" == *"watchdog_silent_max_secs"* ]]
    [[ "$output" == *"60"* ]]
}

@test "an out-of-range analyze_silent_secs warns once and the static legs still run (#932)" {
    devagent_config_set_int "$(_static_cfg)" "project.$TEST_PROJECT.analyze_silent_secs" 0
    _static_window_stubs
    run env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$STATIC_ID" DEVAGENT_ANALYZE_TIMEOUT=70 \
        "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVAGENT_TMP/seen-window")" = "$(printf 'cmake 70\npython 70')" ]
    printf '%s\n' "$output" > "$DEVAGENT_TMP/out.txt"
    [ "$(grep -c 'analyze_silent_secs' "$DEVAGENT_TMP/out.txt")" -eq 1 ]
}
