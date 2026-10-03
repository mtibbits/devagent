#!/usr/bin/env bats
# #55: diff-scoped shellcheck analyzer — findings are NEW iff their line falls
# in a changed hunk range vs baseline (static_analysis_diff.py's filter_novel
# semantics; no baseline shellcheck run, no worktree).
load 'helpers/common'

setup() {
    devagent_test_setup
    export DEVAGENT_DATE_OVERRIDE=1999-01-02   # #338: freeze the analyze date
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

_artifact() { echo "$DEVDOC_DIR/Issue-1/analysis/${DEVAGENT_DATE_OVERRIDE}-shellcheck.txt"; }

# #657: _shadow_shellcheck_version <rc> <text> — PATH-shadow `shellcheck` so
# `--version` prints <text> (printf %b escapes, so a CR stays an escape in this
# source) with exit <rc>, while every other call execs the REAL binary — the
# findings stay real. Unquoted heredoc (the devagent_stub idiom): $real, the
# fixture path and <rc> are baked in at write time; the runtime references are
# escaped.
_shadow_shellcheck_version() {
    local rc="$1"
    printf '%b' "$2" > "$DEVAGENT_TMP/sc-version.txt"
    local real
    real="$(command -v shellcheck)"
    [ "$real" != "$DEVAGENT_STUB_BIN/shellcheck" ] || return 1
    cat > "$DEVAGENT_STUB_BIN/shellcheck" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    cat "$DEVAGENT_TMP/sc-version.txt"
    exit $rc
fi
exec "$real" "\$@"
STUB
    chmod +x "$DEVAGENT_STUB_BIN/shellcheck"
}

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

@test "untracked shell file is scoped with a whole-file range and its finding is NEW (#591)" {
    # The TRACKED sibling of this test is "file added since baseline is scoped and
    # scanned (#55)", which `git add`s the file. This one does NOT: an untracked
    # *.sh produced no diff hunks at all, so it never entered scope and every
    # warning in it counted as pre-existing. The SC2164 sits on line 3 — an
    # INTERIOR line, so a line-1-only range cannot pass this.
    printf '#!/usr/bin/env bash\necho one\ncd /untracked-new\n' > "$SOURCE_DIR/fresh.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'fresh.sh' "$(_artifact)"
    grep -q 'fresh.sh:3' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"
}

@test "a gitignored untracked shell file is NOT scoped (#591)" {
    printf 'skipme.sh\n' > "$SOURCE_DIR/.gitignore"
    ( cd "$SOURCE_DIR" && git add .gitignore && git commit -q -m gitignore )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" \
        baseline_sha "$(cd "$SOURCE_DIR" && git rev-parse HEAD)"
    printf '#!/usr/bin/env bash\ncd /ignored\n' > "$SOURCE_DIR/skipme.sh"
    printf '#!/usr/bin/env bash\ncd /seen\n' > "$SOURCE_DIR/seen.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    # POSITIVE CONTROL: the sweep DID run, so skipme.sh's absence is an exclusion
    # rather than an empty enumeration (register: Issue-337).
    grep -q 'seen.sh' "$(_artifact)"
    # Precise no-match (rc 1), never `-ne 0`: grep's rc 2 ("could not open the
    # artifact") satisfies `-ne 0` vacuously (register: Issue-337).
    run grep -c 'skipme\.sh' "$(_artifact)"
    [ "$status" -eq 1 ]
}

@test "a TRACKED file with only pure-deletion hunks gets no whole-file range (#591)" {
    # #591's whole-file range is keyed on UNTRACKEDNESS, never on "this file has
    # no hunks". tool.sh's baseline SC2164 is on line 2; a 1..N range for a
    # deletion-only diff would report that pre-existing finding as NEW. The #55
    # "trailing pure-deletion hunk" test shares this property incidentally — this
    # one NAMES it, so a regression reddens with its reason attached.
    sed -i '$d' "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'tool.sh' "$(_artifact)"          # it IS in scope
    grep -q 'NEW findings: 0' "$(_artifact)"  # but carries no range
}

@test "an untracked shell file with a non-ASCII name is scoped, not silently dropped (#591)" {
    # ls-files QUOTES such a name by default ("caf\303\251.sh" — measured on git
    # 2.55); the quoted form fails the -f test and vanishes, the silent direction
    # this issue removes (improve bug 2). The finding sits on line 2 of each file.
    printf '#!/usr/bin/env bash\ncd /accent\n' > "$SOURCE_DIR/café.sh"
    printf '#!/usr/bin/env bash\ncd /plain\n' > "$SOURCE_DIR/plain.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'plain.sh:2' "$(_artifact)"   # positive control
    grep -q 'café.sh:2' "$(_artifact)"
}

@test "a TRACKED shell file with a non-ASCII name is scoped, not silently dropped (#591)" {
    # redmr 2026-09-06 MINOR: core.quotePath=false was applied to the untracked
    # enumeration only. `git diff --name-only` QUOTES the same name
    # ("caf\303\251.sh") by default, so a TRACKED café.sh failed the -f test and
    # vanished from scope — the identical silent direction, one call up. Both
    # files are committed since baseline (tracked, never untracked); plain.sh is
    # the positive control. The finding sits on line 2 of each.
    printf '#!/usr/bin/env bash\ncd /accent\n' > "$SOURCE_DIR/café.sh"
    printf '#!/usr/bin/env bash\ncd /plain\n' > "$SOURCE_DIR/plain.sh"
    ( cd "$SOURCE_DIR" && git add café.sh plain.sh && git commit -q -m "add both" )
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'plain.sh:2' "$(_artifact)"   # positive control
    grep -q 'café.sh:2' "$(_artifact)"
}

@test "the artifact header names each untracked file on one exact line (#591)" {
    # The shell family's artifact-visible notice — the twin of the python
    # `Untracked files (whole-file scope):` line. Anchored both ends: no trailing
    # space, nothing else on the line.
    printf '#!/usr/bin/env bash\necho ok\n' > "$SOURCE_DIR/fresh.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q '^untracked (whole-file scope): fresh.sh$' "$(_artifact)"
}

@test "the artifact header stamps the analyzer version on one exact line (#657)" {
    _shadow_shellcheck_version 0 \
        'ShellCheck - shell script analysis tool\nversion: 9.9.9-stub\nlicense: GNU General Public License, version 3\n'
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    [ "$(grep -c '^analyzer:' "$(_artifact)")" -eq 1 ]
    grep -qx 'analyzer: shellcheck 9.9.9-stub' "$(_artifact)"
    # Placement is RELATIVE (never an absolute line number): a header data line,
    # ahead of the variable-length scope list.
    local analyzer_ln scope_ln
    analyzer_ln="$(grep -n '^analyzer:' "$(_artifact)" | cut -d: -f1)"
    scope_ln="$(grep -n '^scope:' "$(_artifact)" | cut -d: -f1)"
    [ "$analyzer_ln" -lt "$scope_ln" ]
    # DELEGATION CONTROL: the shadow handed the findings run to the real binary —
    # one that answered every call with the canned text finds nothing.
    grep -q 'SC2164' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"
}

@test "a CRLF --version stamps the version without a carriage return (#657)" {
    # A Windows shellcheck build prints CRLF; the stamp must not carry the CR.
    _shadow_shellcheck_version 0 \
        'ShellCheck - shell script analysis tool\r\nversion: 9.9.9-stub\r\nlicense: x\r\n'
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -qx 'analyzer: shellcheck 9.9.9-stub' "$(_artifact)"
    # Precise no-match (rc 1), never `-ne 0` (register: Issue-337).
    run grep -c $'\r' "$(_artifact)"
    [ "$status" -eq 1 ]
}

@test "an unreadable --version stamps (version unknown) and analysis still runs (#657)" {
    # No `version:` line AND a failing exit: neither may stop step 13 (no runtime
    # version gate), and the degraded reading is spelled out, never left empty.
    _shadow_shellcheck_version 2 'garbage\n'
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -qx 'analyzer: shellcheck (version unknown)' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"   # analysis ran to the end
}

@test "the real shellcheck --version stamps a dotted version (#657)" {
    # No shadow: the ONE permitted shape, against whatever shellcheck is installed —
    # an upstream `--version` format change reddens here, never at runtime.
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'scope: 0 file' "$(_artifact)"   # path control: the empty-scope exit carries it too
    grep -qE '^analyzer: shellcheck [0-9]+\.[0-9]+\.[0-9]+$' "$(_artifact)"
}

@test "the analyzer header records its version policy (#657 AC2)" {
    # The header region only — a mention elsewhere in the file cannot satisfy it.
    local hdr
    hdr="$(sed -n '1,/^set -euo pipefail$/p' "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh")"
    grep -q '^# Analyzer version (#657):' <<<"$hdr"
    grep -q 'no runtime version gate' <<<"$hdr"
    grep -q 'CONTRIBUTING.md' <<<"$hdr"
}

@test "a relative PATH entry still scans with the stamped binary after the cd (#657)" {
    # `command -v` answers a relative PATH entry with a relative path, and the
    # findings run cds into source_dir before it execs: unanchored, nothing runs
    # there and `|| true` stamps a vacuous NEW findings: 0 (redmr, 2026-10-02).
    local rel="$DEVAGENT_TMP/relpath"
    mkdir -p "$rel/bin"
    ln -s "$(command -v shellcheck)" "$rel/bin/shellcheck"
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    # shellcheck disable=SC2016  # $1 is bash -c's own positional, expanded there
    run bash -c 'cd "$1" && shift && exec env "$@"' _ "$rel" \
        PATH="bin:$PATH" \
        HOME="$HOME" \
        DEVAGENT_ROOT="$DEVAGENT_ROOT" \
        bash "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^analyzer: shellcheck [^(]' "$(_artifact)"   # a version was stamped
    grep -q 'SC2164' "$(_artifact)"
    grep -qE 'NEW findings: [1-9]' "$(_artifact)"
}

# ---- #675: the scan's exit status is classified, never swallowed ----

# A failed scan writes NO count line. It uses `run`, so it clobbers
# $status/$output: call it LAST, after every analyzer assertion.
_no_count_lines() {
    run grep -cE '^(total findings in scoped files|NEW findings):' "$(_artifact)"
    [ "$status" -eq 1 ]
}

@test "a scoped file vanishing before the scan fails loud: exit=2, no count lines (#675)" {
    # The shadow deletes the scoped untracked new.sh on the findings call, then
    # execs the REAL binary: shellcheck reports tool.sh's finding and exits 2 on
    # the missing file. Pass-through shadow, inline until #681's helper lands.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    printf '#!/usr/bin/env bash\ncd /gone\n' > "$SOURCE_DIR/new.sh"
    local real
    real="$(command -v shellcheck)"
    [ "$real" != "$DEVAGENT_STUB_BIN/shellcheck" ]
    cat > "$DEVAGENT_STUB_BIN/shellcheck" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" != "--version" ]; then
    rm -f "$SOURCE_DIR/new.sh"
fi
exec "$real" "\$@"
STUB
    chmod +x "$DEVAGENT_STUB_BIN/shellcheck"
    run_shellcheck_analyzer
    [ "$status" -eq 1 ]
    # Die-only fragment: the echoed artifact alone carries a bare `exit=2`.
    [[ "$output" == *"scan FAILED (exit=2)"* ]]
    [[ "$output" == *"$(_artifact)"* ]]
    grep -qx 'shellcheck: exit=2' "$(_artifact)"
    grep -qE '^tool\.sh:4:.*SC2164' "$(_artifact)"   # stdout kept verbatim
    grep -q 'openBinaryFile' "$(_artifact)"          # stderr kept verbatim
    _no_count_lines
}

@test "an exec failure after a good --version fails loud: exit=127, real version stamped (#675)" {
    # The shadow answers --version through the real binary, deleting itself
    # first: the findings call then finds no binary at the stamped path.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    local real
    real="$(command -v shellcheck)"
    [ "$real" != "$DEVAGENT_STUB_BIN/shellcheck" ]
    cat > "$DEVAGENT_STUB_BIN/shellcheck" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    rm -f "\$0"
    exec "$real" --version
fi
exec "$real" "\$@"
STUB
    chmod +x "$DEVAGENT_STUB_BIN/shellcheck"
    run_shellcheck_analyzer
    [ "$status" -eq 1 ]
    [[ "$output" == *"scan FAILED (exit=127)"* ]]
    grep -qx 'shellcheck: exit=127' "$(_artifact)"
    grep -qE '^analyzer: shellcheck [0-9]+\.[0-9]+\.[0-9]+$' "$(_artifact)"
    _no_count_lines
}

@test "an option-shaped untracked name (-x.sh) is scanned after -- (#675)" {
    # Counts first: without `--` the name is parsed as options, so the red
    # comes from the missing `--`, not only from the missing exit line.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    printf '#!/usr/bin/env bash\ncd /x\n' > "$SOURCE_DIR/-x.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -qx 'total findings in scoped files: 3' "$(_artifact)"
    grep -q '^NEW findings: 2 ' "$(_artifact)"
    grep -qx 'shellcheck: exit=1' "$(_artifact)"
}

@test "a clean scope records shellcheck: exit=0 between the header and the counts (#675)" {
    printf '#!/usr/bin/env bash\necho ok\n' > "$SOURCE_DIR/fresh.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    [ "$(grep -c '^shellcheck: ' "$(_artifact)")" -eq 1 ]
    grep -qx 'shellcheck: exit=0' "$(_artifact)"
    grep -q '^NEW findings: 0 ' "$(_artifact)"
    # Placement is RELATIVE (never an absolute line number).
    local untracked_ln exit_ln total_ln
    untracked_ln="$(grep -n '^untracked (whole-file scope):' "$(_artifact)" | cut -d: -f1)"
    exit_ln="$(grep -n '^shellcheck: ' "$(_artifact)" | cut -d: -f1)"
    total_ln="$(grep -n '^total findings in scoped files:' "$(_artifact)" | cut -d: -f1)"
    [ "$untracked_ln" -lt "$exit_ln" ]
    [ "$exit_ln" -lt "$total_ln" ]
}

@test "an -o-shaped name (-ofoo.sh) is scanned, not consumed as -o's argument (#675)" {
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    printf '#!/usr/bin/env bash\ncd /o\n' > "$SOURCE_DIR/-ofoo.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q '^NEW findings: 2 ' "$(_artifact)"
    grep -qx 'shellcheck: exit=1' "$(_artifact)"
}

@test "a --rcfile=-shaped name cannot turn a scoped file into the rcfile (#675)" {
    # Unprotected, `--rcfile=rc.sh` loads rc.sh's `disable=all` and hides
    # tool.sh's new finding.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    printf '#!/usr/bin/env bash\ncd /hidden\n' > "$SOURCE_DIR/--rcfile=rc.sh"
    printf 'disable=all\n' > "$SOURCE_DIR/rc.sh"
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q '^tool\.sh:4:.*SC2164' "$(_artifact)"
    grep -qx 'shellcheck: exit=1' "$(_artifact)"
}

@test "a cd into source_dir that fails after scoping writes not run and dies (#675)" {
    # `git -C` dies first on an unreachable source_dir (:97/:120), so the scan's
    # own cd is reached only by moving source_dir away after the last git call
    # before the scan (ls-files). The shim keeps the real git's rc.
    printf 'cd /brand-new\n' >> "$SOURCE_DIR/tool.sh"
    local real_git
    real_git="$(command -v git)"
    [ "$real_git" != "$DEVAGENT_STUB_BIN/git" ]
    cat > "$DEVAGENT_STUB_BIN/git" <<STUB
#!/usr/bin/env bash
"$real_git" "\$@"
rc=\$?
case " \$* " in
    *" ls-files "*)
        if [ -d "$SOURCE_DIR" ]; then mv "$SOURCE_DIR" "$SOURCE_DIR.gone"; fi ;;
esac
exit \$rc
STUB
    chmod +x "$DEVAGENT_STUB_BIN/git"
    run_shellcheck_analyzer
    [ "$status" -eq 1 ]
    [[ "$output" == *"scan not run: cd into source_dir"* ]]
    grep -qx 'shellcheck: not run (cd into source_dir failed)' "$(_artifact)"
    run grep -c '^shellcheck: exit=' "$(_artifact)"
    [ "$status" -eq 1 ]
    _no_count_lines
}

@test "the empty-scope path runs no scan and writes no shellcheck: line (#675)" {
    # Green before #675 by design: pins that the exit line stays below the
    # empty-scope exit.
    run_shellcheck_analyzer
    [ "$status" -eq 0 ]
    grep -q 'NEW findings: 0 (empty scope)' "$(_artifact)"
    run grep -c '^shellcheck: ' "$(_artifact)"
    [ "$status" -eq 1 ]
}

@test "the analyzer header states the failure split and gives #117 no ownership (#675)" {
    local script="$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh"
    local hdr
    hdr="$(sed -n '1,/^set -euo pipefail$/p' "$script")"
    grep -q 'fails step 13 loud' <<<"$hdr"
    grep -qi 'report-not-fail' <<<"$hdr"
    run grep -c "#117's remit" "$script"
    [ "$status" -eq 1 ]
    run grep -c '#117 owns' "$script"
    [ "$status" -eq 1 ]
    grep -q 'the #117 class' "$script"   # positive control: the scan saw the file
    grep -qF 'shellcheck: exit=<rc>' "$DEVAGENT_ROOT/commands/analyze.md"
}
