#!/usr/bin/env bats
# #55: diff-scoped shellcheck analyzer — findings are NEW iff their line falls
# in a changed hunk range vs baseline (static_analysis_diff.py's filter_novel
# semantics; no baseline shellcheck run, no worktree).
load 'helpers/common'

setup() {
    devagent_test_setup
    # Baseline commit: a script with a PRE-EXISTING warning (SC2164, bare cd)
    # on a line the branch never touches, plus a clean line. (SC2086 is only
    # info-level — below the --severity=warning cutoff — verified live.)
    cat > "$SOURCE_DIR/tool.sh" <<'SH'
#!/usr/bin/env bash
cd /pre-existing
echo "clean line"
SH
    ( cd "$SOURCE_DIR" \
      && git add tool.sh && git commit -q -m baseline )
    BASELINE_SHA="$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "fix/1-x"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE_SHA"
}
teardown() { devagent_test_teardown; }

run_shellcheck_analyzer() {
    run env \
        HOME="$HOME" \
        DEVAGENT_ROOT="$DEVAGENT_ROOT" \
        bash "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh" "$TEST_PROJECT" Issue-1
}

_artifact() { echo "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-shellcheck.txt"; }

@test "new warning on a changed line is reported as NEW (#55)" {
    # Append a new bare cd — a changed (added) line with warning-level SC2164.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    [ -f "$(_artifact)" ]
    grep -q 'SC2164' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"
}

@test "pre-existing warning on an untouched line is NOT new (#55)" {
    # Touch only the clean line; the baseline SC2164 on line 2 is untouched.
    sed -i 's/clean line/clean line v2/' "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'NEW findings: 0' "$(_artifact)"
}

@test "no shell files changed: empty scope recorded, exit 0 (#55)" {
    echo "docs" > "$SOURCE_DIR/README.md"
    ( cd "$SOURCE_DIR" && git add README.md )
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'scope: 0 file' "$(_artifact)"
}

@test "file deleted since baseline does not crash the run (#55)" {
    ( cd "$SOURCE_DIR" && git rm -q tool.sh )
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'scope: 0 file' "$(_artifact)"
}

@test "file added since baseline is scoped and scanned (#55)" {
    printf '#!/usr/bin/env bash\ncd /somewhere\n' > "$SOURCE_DIR/new.sh"
    ( cd "$SOURCE_DIR" && git add new.sh )
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'new.sh' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"
}

@test "trailing pure-deletion hunk does not kill the run (#55 review HIGH)" {
    # Deleting the LAST line makes the file's final hunk `+c,0` — the range
    # loop's tail status must not propagate through set -e.
    sed -i '$d' "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'NEW findings: 0' "$(_artifact)"
}

@test "dot-sibling filename does not cross-match findings (#55 review MED)" {
    # a.b.sh is changed with ranges covering line 2; axb.sh's warning sits on
    # its UNtouched line 2. A regex-y `grep ^a.b.sh:` would claim axb.sh:2.
    printf '#!/usr/bin/env bash\ncd /pre\necho ok\n' > "$SOURCE_DIR/axb.sh"
    ( cd "$SOURCE_DIR" && git add axb.sh && git commit -q -m axb )
    BASELINE_SHA="$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE_SHA"
    printf '#!/usr/bin/env bash\necho two\necho three\n' > "$SOURCE_DIR/a.b.sh"
    ( cd "$SOURCE_DIR" && git add a.b.sh )
    printf 'echo touched-tail\n' >> "$SOURCE_DIR/axb.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'NEW findings: 0' "$(_artifact)"
}

@test "an unresolvable baseline dies loud without a vacuous empty-scope pass (#314)" {
    # A bad baseline ref makes `git diff` fail. The pre-#314 code ran that diff
    # inside a process substitution whose non-zero exit was invisible → files=()
    # → the "empty scope" branch → exit 0: a VACUOUS pass that let analyze.sh
    # mark step 11 [x] with zero analysis. It must die loud instead.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "no-such-baseline-ref-314"
    run_shellcheck_analyzer
    [ "$status" -ne 0 ]
    # A die-only fragment: "baseline:" also prints on the empty-scope artifact,
    # so pin the failure path with a phrase that never appears on a pass (#314 review).
    [[ "$output" == *"unresolvable"* ]]
    [[ "$output" == *"no-such-baseline-ref-314"* ]]   # names the offending baseline
    [ ! -f "$(_artifact)" ]                # no success artifact was written
}

@test "missing shellcheck binary dies loud without a success artifact (#55)" {
    stub="$DEVAGENT_TMP/no-shellcheck-path"
    mkdir -p "$stub"
    for t in bash git sed grep sort wc date mkdir tee cat env dirname python3 awk cut tr head tail uname; do
        p="$(command -v "$t" 2>/dev/null || true)"
        [ -n "$p" ] && ln -s "$p" "$stub/$t"
    done
    run env PATH="$stub" \
        HOME="$HOME" \
        DEVAGENT_ROOT="$DEVAGENT_ROOT" \
        bash "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"shellcheck"* ]]
    [ ! -f "$(_artifact)" ]
}
