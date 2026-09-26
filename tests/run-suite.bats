#!/usr/bin/env bats
# #359 run-suite.sh. bats is stubbed to controlled TAP for determinism and speed
# (the counting logic — grep '^ok ' + the 1..N plan line, NEVER the tail, #85 — is
# what this exercises). NB: an earlier version of this comment said bats "cannot
# nest inside a bats run"; #565 measured that false at bats 1.10.0 and 1.14.0, and
# tests/locale-registration.bats nests deliberately. Stubbing is still right here;
# impossibility was never the reason.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    mkdir -p "$DEVAGENT_TMP/binstub"
    # Stub bats: 3 planned, 2 ok, 1 not ok — plan(3) != ok-count(2), so a tail-based
    # count would be wrong; run-suite must report 2/3 notok=1.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..3"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "not ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

@test "run-suite writes counts from grep+plan (not tail) and dirty state (#359)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
    grep -q '^pytest: (none)$' "$art"           # no tests/test_*.py present
    grep -qE '^head: [0-9a-f]+  dirty: no$' "$art"
}

@test "run-suite records notok>0 on a failing tree (#359 AC)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q 'notok=1' "$art"
}

@test "run-suite dies loud when bats emits no plan line (#359)" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo "some error, no plan"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"plan line"* ]]
}

@test "run-suite dies loud on a TRUNCATED run — plan present but ok+notok<plan (#406)" {
    # bats --tap emits 1..N first; a killed/crashed run leaves a full plan but
    # fewer ok/not-ok lines. Stub that shape: plan 5, only 3 ok, 0 not ok.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..5"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"truncated"* ]]
    [[ "$output" == *"3 of 5"* ]]
}

@test "run-suite does NOT false-die on a legitimately-failing full run (#406)" {
    # plan 3, 2 ok + 1 not ok — ok+notok == plan, so no truncation; a normal
    # (failing) run must still write the artifact and exit 0.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..3"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "not ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
}

# Stub python3 so the pytest branch sees a controlled summary, while DELEGATING
# every non-pytest call (config/state parse `python3 _toml.py`, #116) to the real
# interpreter — resolved before binstub goes on PATH.
_stub_python3_pytest() {
    local summary="$1" real_py3
    real_py3="$(command -v python3)"
    cat > "$DEVAGENT_TMP/binstub/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *pytest*) echo "$summary" ;;
  *) exec "$real_py3" "\$@" ;;
esac
EOF
    chmod +x "$DEVAGENT_TMP/binstub/python3"
}

@test "run-suite parses a line-start pytest summary (count at column 0)" {
    # Regression: pytest -q's summary "285 passed, 9 skipped in Xs" BEGINS with
    # the count. The old sed 's/.*[^0-9]\([0-9]*\) passed/' required a non-digit
    # BEFORE the digits, so a line-start count matched nothing -> recorded 0.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "285 passed, 9 skipped in 0.01s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 285 passed, 0 failed, 0 errors$' "$art"
}

@test "run-suite records pytest: (error) when tests exist but pytest emits no count (#466)" {
    # Was the "(none) false-green guard" until #466. Its INTENT is preserved and
    # strengthened, not dropped: never record a green for a suite that was never
    # measured. What changes is the TOKEN. `(none)` was doing two jobs — "this project
    # has no pytest suite" and "this project's pytest suite could not be measured" —
    # and preship-evidence reconstructs the Evidence line from framework PRESENCE, so
    # the shared token let an unmeasured suite vanish out of the green entirely.
    # Splitting it makes the fail-safe un-violatable by construction (register
    # Issue-243). tests/test_*.py existing does NOT mean pytest can run them: a missing
    # interpreter (Windows Store shim), a venv without pytest, a `venv/`-spelled
    # environment, or a collection error all emit no summary.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    # A collection error: pytest exits non-zero and prints no category count. (The
    # original form of this test stubbed rc 0 with unparseable output — a combination
    # real pytest never produces, since a 0 exit always carries a summary. The tri-state
    # now keys on the exit code, so the stub has to be a shape that can actually occur.)
    _stub_python3_pytest_rc "ImportError while loading conftest: no module named pytest" 4
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: (error)$' "$art"
}

@test "run-suite prefers <tree>/.venv/bin/python over ambient python3 (#466)" {
    # factor-ai Issue-9: a 51-test pytest suite recorded "0 passed" because the project
    # keeps its interpreter in .venv/ and run-suite measured with ambient python3.
    echo 'def test_ok(): pass' > tests/test_stub.py
    mkdir -p .venv/bin
    printf '%s\n' '#!/usr/bin/env bash' 'echo "51 passed in 44.69s"' > .venv/bin/python
    chmod +x .venv/bin/python
    git add -A && git commit -q -m "add py test and venv"
    # Ambient python3 still answers config/state calls (_stub_python3_pytest delegates
    # every non-pytest call to the real interpreter), but produces NO pytest summary —
    # so a non-zero count in the artifact can ONLY have come from .venv/bin/python.
    # That is the venv proof: a behavioural assertion, not a provenance label.
    _stub_python3_pytest "ambient python3 cannot run pytest in this tree"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 51 passed, 0 failed, 0 errors$' "$art"
}

@test "run-suite parses a mixed failed+passed pytest summary (order-independent)" {
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "3 failed, 282 passed in 0.02s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 282 passed, 3 failed, 0 errors$' "$art"
}

@test "run-suite artifact name honors DEVAGENT_DATE_OVERRIDE (#413/#338)" {
    export DEVAGENT_DATE_OVERRIDE=2020-02-02
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/2020-02-02-suite-count.txt" ]
}

@test "#571 AC3: the head:/dirty: stamp survives, and the artifact records its tree" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    # head: is the FIRST data line and carries BOTH fields (register Issue-572)
    run head -1 "$art"
    printf '%s\n' "$output" | grep -qE '^head: [0-9a-f]+  dirty: (yes|no)$'
    # tree: is an IDENTITY — canonical (pwd -P) on both sides; precise count,
    # never -ne 0 (register Issue-337)
    run grep -c '^tree: ' "$art"
    [ "$output" -eq 1 ]
    grep -q "^tree: $(cd "$SOURCE_DIR" && pwd -P)$" "$art"
}

@test "#571/#659 AC5: the core-draft-mr skill's documented command, run verbatim, lands in the issue it names" {
    # The command is READ from the SKILL (register Issue-106: running a VARIANT of a
    # published command is not running it), its two placeholders filled, and run
    # under a SPACED plugin root (Issue-597: benign substitutions hide quoting
    # defects). The SKILL carries the matching editor note (Issue-461/583).
    local skill="$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md" line cmd art
    [ "$(grep -c 'scripts/run-suite\.sh"' "$skill")" -eq 1 ]      # one published form
    line="$(grep 'scripts/run-suite\.sh"' "$skill")"
    cmd="${line%%#*}"                                             # drop the trailing comment
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ "$cmd" = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-suite.sh" <project> <Issue-N>' ]
    cmd="${cmd/<project>/$TEST_PROJECT}"; cmd="${cmd/<Issue-N>/Issue-2}"
    mkdir -p "$DEVDOC_DIR/Issue-2"
    ln -s "$DEVAGENT_ROOT" "$DEVAGENT_TMP/plugin root"
    CLAUDE_PLUGIN_ROOT="$DEVAGENT_TMP/plugin root" PATH="$DEVAGENT_TMP/binstub:$PATH" run bash -c "$cmd"
    [ "$status" -eq 0 ]
    _empty659 Issue-1                                              # not the shared slot's issue
    art="$(ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt)"
    grep -qE '^head: [0-9a-f]+  dirty: (yes|no)$' "$art"
    run grep -c '^tree: ' "$art"
    [ "$output" -eq 1 ]
    grep -q '^bats: ' "$art"
    grep -q '^pytest: ' "$art"
}

@test "#565: run-suite hands bats a UTF-8 locale, whatever the invoking shell" {
    # Stub bats records the locale it was invoked with, then emits a valid plan.
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s" "${LC_ALL:-<unset>}" > "$DEVAGENT_TMP/seen-lc-all"' \
        'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    # Invoke from a locale-empty shell — the shape that silently drops tests.
    # LC_CTYPE is scrubbed too: it outranks LANG for character semantics, so
    # unsetting only LC_ALL/LANG does not model a locale-empty shell.
    # DEVAGENT_TMP is already exported by devagent_test_setup; the stub sees it.
    PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run env -u LC_ALL -u LC_CTYPE -u LANG "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    seen="$(cat "$DEVAGENT_TMP/seen-lc-all")"
    [ "$seen" != "<unset>" ]
    # Assert the CLAIM, not the token (#561): whatever was passed must give bash
    # multibyte semantics.
    run env LC_ALL="$seen" bash -c 'e="$(printf "\xe2\x80\x94")"; printf "%s" "${#e}"'
    [ "$output" = "1" ]
}

# --- #603: [project.<name>.suite_env] exported into the suite children --------
#
# Motivating case: lawFirm keeps its data layer outside git (its SCHEMA §1), so
# every entry point dies without LAWFIRM_DATA_ROOT and run-suite recorded a red
# suite that said nothing about the branch. Before #603 the only way in was
# INHERITANCE from the invoking shell, which makes the artifact a function of the
# operator's session rather than the tree (#458).

# Stub python3 to RECORD WHAT IT SAW in the environment to a side-channel file, so
# these tests assert the variable actually reached the child rather than that the
# config parsed. The value goes to a file rather than into pytest's summary line
# because the summary's count field is parsed as digits — encoding a path or a
# word there would be swallowed by the parser and the assertion would pass or
# fail for the wrong reason.
_stub_python3_record_env() {
    local var="$1" real_py3
    real_py3="$(command -v python3)"
    : > "$DEVAGENT_TMP/seen-env.txt"
    cat > "$DEVAGENT_TMP/binstub/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *pytest*)
    printf '%s\\n' "\${$var-<UNSET>}" > "$DEVAGENT_TMP/seen-env.txt"
    echo "5 passed in 0.01s" ;;
  *) exec "$real_py3" "\$@" ;;
esac
EOF
    chmod +x "$DEVAGENT_TMP/binstub/python3"
}

@test "#603 suite_env: a declared variable reaches the pytest child" {
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
DEVAGENT_SUITE_PROBE = "4242"
EOF
    _stub_python3_record_env DEVAGENT_SUITE_PROBE
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    [ "$(cat "$DEVAGENT_TMP/seen-env.txt")" = "4242" ]
    grep -q '^suite_env: DEVAGENT_SUITE_PROBE$' "$art"
}

@test "#603 suite_env: BORN-RED control — without the table the child sees nothing" {
    # The mutation-proof for the test above: same stub, no table declared. If this
    # ever reports a value, the variable is arriving by inheritance and the test
    # above proves nothing.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_record_env DEVAGENT_SUITE_PROBE
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    [ "$(cat "$DEVAGENT_TMP/seen-env.txt")" = "<UNSET>" ]
    grep -q '^suite_env: (none)$' "$art"
}

@test "#603 suite_env: the declared value WINS over an inherited one" {
    # Determinism is the point: the artifact must describe the tree, not the shell.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
DEVAGENT_SUITE_PROBE = "fromconfig"
EOF
    _stub_python3_record_env DEVAGENT_SUITE_PROBE
    DEVAGENT_SUITE_PROBE=fromshell PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVAGENT_TMP/seen-env.txt")" = "fromconfig" ]
}

@test "#603 suite_env: a tilde value is expanded" {
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
DEVAGENT_SUITE_PROBE = "~/probe-dir"
EOF
    _stub_python3_record_env DEVAGENT_SUITE_PROBE
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVAGENT_TMP/seen-env.txt")" = "$HOME/probe-dir" ]
    [ "$(cat "$DEVAGENT_TMP/seen-env.txt")" != "~/probe-dir" ]
}

@test "#603 suite_env: an EMPTY declared value dies loud (fail-closed)" {
    # A silently-empty export is indistinguishable from the unset variable the
    # table exists to supply — the failure it is meant to prevent, wearing a
    # well-formed artifact.
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
DEVAGENT_SUITE_PROBE = ""
EOF
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"is empty"* ]]
    # Died BEFORE writing an artifact.
    run ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    [ "$status" -ne 0 ]
}

@test "#603 suite_env: an illegal variable NAME dies loud (fail-closed)" {
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
"not-a-valid-name" = "x"
EOF
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid environment-variable name"* ]]
}

@test "#603 suite_env: the artifact records NAMES, never values" {
    # The artifact is quoted into MR bodies; a declared variable may hold a token.
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.suite_env]
DEVAGENT_SUITE_PROBE = "s3cr3t-value"
EOF
    _stub_python3_pytest "5 passed in 0.01s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^suite_env: DEVAGENT_SUITE_PROBE$' "$art"
    run grep -q 's3cr3t-value' "$art"
    [ "$status" -ne 0 ]
}

@test "run-suite: DEVAGENT_PYTEST_PYTHON overrides the interpreter search (#466)" {
    # The seam exists so an unsupported venv layout (`venv/`, `.venv/Scripts/`, conda,
    # uv, pyenv) or a linked worktree — where an untracked .venv never travels — is
    # merely unsupported rather than UNSHIPPABLE, since the (error) arm has no bypass.
    # Point it at an interpreter that reports a count while BOTH ambient python3 and a
    # present .venv report none: only the override can produce the recorded number.
    echo 'def test_ok(): pass' > tests/test_stub.py
    mkdir -p .venv/bin
    printf '%s\n' '#!/usr/bin/env bash' 'echo "venv also cannot run pytest"' > .venv/bin/python
    chmod +x .venv/bin/python
    mkdir -p "$DEVAGENT_TMP/elsewhere"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "7 passed in 0.10s"' \
        > "$DEVAGENT_TMP/elsewhere/python"
    chmod +x "$DEVAGENT_TMP/elsewhere/python"
    git add -A && git commit -q -m "add py test and a pytest-less venv"
    _stub_python3_pytest "ambient python3 cannot run pytest in this tree"
    DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/elsewhere/python" \
        PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 7 passed, 0 failed, 0 errors$' "$art"
}

@test "run-suite: an unset DEVAGENT_PYTEST_PYTHON does not disturb the .venv preference (#466)" {
    # Guards the seam's empty case: `${DEVAGENT_PYTEST_PYTHON:-}` must fall through to
    # the search, not resolve to an empty command.
    echo 'def test_ok(): pass' > tests/test_stub.py
    mkdir -p .venv/bin
    printf '%s\n' '#!/usr/bin/env bash' 'echo "51 passed in 44.69s"' > .venv/bin/python
    chmod +x .venv/bin/python
    git add -A && git commit -q -m "add py test and venv"
    _stub_python3_pytest "ambient python3 cannot run pytest in this tree"
    DEVAGENT_PYTEST_PYTHON="" PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 51 passed, 0 failed, 0 errors$' "$art"
}

# #466: _stub_python3_pytest emits a summary and exits 0. These cases need control of
# the EXIT CODE too, since that is what the tri-state now keys on. $1=summary $2=rc
_stub_python3_pytest_rc() {
    local summary="$1" rc="$2" real_py3
    real_py3="$(command -v python3)"
    cat > "$DEVAGENT_TMP/binstub/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *pytest*) echo "$summary"; exit $rc ;;
  *) exec $real_py3 "\$@" ;;
esac
EOF
    chmod +x "$DEVAGENT_TMP/binstub/python3"
}
_seed_py() { echo 'def test_ok(): pass' > tests/test_stub.py; git add -A && git commit -q -m "add py test"; }
_art() { ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt; }
_run_rs() { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1; }

@test "run-suite: an ALL-SKIPPED suite (rc 0) records a truthful 0/0 (#466 review MAJOR-1)" {
    # The normal shape for a platform/optional-dependency skipif suite. It RAN; its
    # measurement is zero. Recording (error) made healthy projects unshippable.
    _seed_py; _stub_python3_pytest_rc "1 skipped in 0.00s" 0
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 0 passed, 0 failed, 0 errors$' "$(_art)"
}

@test "run-suite: a ZERO-COLLECT tree (rc 5) records a truthful 0/0 (#466 review MAJOR-1)" {
    _seed_py; _stub_python3_pytest_rc "no tests ran in 0.00s" 5
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 0 passed, 0 failed, 0 errors$' "$(_art)"
}

@test "run-suite: an ALL-XPASSED suite (rc 0) records 0/0, not (error) (#466 redmr)" {
    # `1 xpassed` was omitted from the first fix's hand-written category list, so a
    # healthy suite recorded (error). Also pins that `xpassed` is not read as `passed`.
    _seed_py; _stub_python3_pytest_rc "1 xpassed in 0.00s" 0
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 0 passed, 0 failed, 0 errors$' "$(_art)"
}

@test "run-suite: a suite that SKIPPED and ERRORED is NOT recorded green (#466 redmr BLOCKING)" {
    # pytest orders its summary `failed, passed, skipped, …, error`, so
    # "1 skipped, 1 error" matched a `^[0-9]+ skipped` prefix and recorded a clean
    # 0 passed, 0 failed — a false green in the exact class this file exists to close.
    _seed_py; _stub_python3_pytest_rc "1 skipped, 1 error in 0.01s" 1
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 0 passed, 0 failed, 1 errors$' "$(_art)"
    run grep -q '^pytest: 0 passed, 0 failed, 0 errors$' "$(_art)"
    [ "$status" -ne 0 ]
}

@test "run-suite: pytest ERRORS beside passes are recorded, not swallowed (#466 redmr)" {
    # "2 passed, 1 error" recorded `0 failed` and shipped green: an error is not a
    # "failed", and nothing in the chain could see it.
    _seed_py; _stub_python3_pytest_rc "2 passed, 1 error in 0.01s" 1
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 2 passed, 0 failed, 1 errors$' "$(_art)"
}

@test "run-suite: a real test FAILURE (rc 1 with counts) is measured, not (error) (#466)" {
    _seed_py; _stub_python3_pytest_rc "1 failed, 2 passed in 0.01s" 1
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 2 passed, 1 failed, 0 errors$' "$(_art)"
}

@test "run-suite: a MISSING pytest module (rc 1, no counts) still records (error) (#466)" {
    # rc 1 is ambiguous — "tests failed" and "no pytest module" share it. The
    # discriminator is whether any count was parsed.
    _seed_py; _stub_python3_pytest_rc "No module named pytest" 1
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: (error)$' "$(_art)"
}

@test "run-suite: an INTERNAL pytest error (rc 3) records (error) (#466)" {
    _seed_py; _stub_python3_pytest_rc "INTERNALERROR> boom" 3
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: (error)$' "$(_art)"
}

@test "run-suite: a pytest suite in a SUBDIRECTORY is found, not called absent (#466 redmr)" {
    # The presence glob was non-recursive while `pytest tests/` collects recursively,
    # so tests/unit/test_*.py read as "no pytest here" — and since #466 makes presence
    # load-bearing, the suite vanished from the Evidence entirely.
    mkdir -p tests/unit && echo 'def test_ok(): pass' > tests/unit/test_stub.py
    git add -A && git commit -q -m "add nested py test"
    _stub_python3_pytest_rc "51 passed in 1.00s" 0
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^pytest: 51 passed, 0 failed, 0 errors$' "$(_art)"
    run grep -q '^pytest: (none)$' "$(_art)"
    [ "$status" -ne 0 ]
}

@test "run-suite: the artifact records WHICH interpreter ran pytest (#466 redmr)" {
    # The artifact is no longer a function of the tree alone — DEVAGENT_PYTEST_PYTHON and
    # the fallback arm both admit an outside interpreter — so it must say which one ran,
    # or an (error) is undiagnosable and the fallback arm is unauditable.
    _seed_py
    mkdir -p "$DEVAGENT_TMP/elsewhere"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "7 passed in 0.10s"' > "$DEVAGENT_TMP/elsewhere/python"
    chmod +x "$DEVAGENT_TMP/elsewhere/python"
    _stub_python3_pytest_rc "ambient cannot run pytest" 1
    DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/elsewhere/python" \
        PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q "^python: $DEVAGENT_TMP/elsewhere/python$" "$(_art)"
}

@test "run-suite: python: is (none) for a tree with no pytest suite (#466 redmr)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^python: (none)$' "$(_art)"
}

# --- #593: suite_jobs → bats --jobs N (test FILES in parallel, tests in a file in order) ---
#
# The knob is config-owned (a project opts in after auditing its suite) with a
# one-run env override for the A/B measurement — the analyze_timeout /
# DEVAGENT_ANALYZE_TIMEOUT shape. Validated BEFORE any suite runs, so a bad
# value dies in milliseconds and leaves no artifact. bats is stubbed to RECORD
# ITS ARGV (a source grep of run-suite.sh would pass on disabled code, #565);
# `parallel` is stubbed through devagent_stub because bats --jobs needs GNU
# parallel and Debian's moreutils ships an unrelated `parallel` with no
# --version — and the stub log lets the serial controls assert the probe never
# ran. In the fail-closed tests the NEGATIVE legs come first: a multi-assert
# test reddens only at its first failing line (Issue-123), and at the unfixed
# tree the run proceeds and writes, so those legs are what must be seen red.
_set_suite_jobs() {   # an integer lands bare (set-int); anything else lands as a quoted string
    # The #335 shared helpers, never a `sed -i` on TOML state (#429): the key lands
    # INSIDE [project.testproj]. The grep pins the TOML shape the skel documents.
    local cfg="$HOME/.claude/devagent/config.toml" key="project.$TEST_PROJECT.suite_jobs"
    case "$1" in
        *[!0-9]*) devagent_config_set     "$cfg" "$key" "$1"; grep -q "^suite_jobs = \"$1\"\$" "$cfg" ;;
        *)        devagent_config_set_int "$cfg" "$key" "$1"; grep -q "^suite_jobs = $1\$" "$cfg" ;;
    esac
}
_stub_bats_record_argv() {   # binstub, not DEVAGENT_STUB_BIN: setup()'s bats stub lives there, first on _run_rs's PATH
    # Records argv WORD-BRACKETED ([--jobs][4]), not "$*"-joined. An IFS-joined line
    # cannot tell `--jobs 4` as two words from `--jobs 4` as ONE word — the latter is
    # what a regression to bats_flags=("--jobs $suite_jobs") produces and what real
    # bats rejects as an unknown option, yet both record the identical `$*` line. That
    # splat is #593's only word-splitting hazard, so the assertion has to see the
    # boundary. The `grep -c -- '--jobs'` no-match controls below are unaffected: they
    # match the substring inside the brackets either way.
    printf '%s\n' '#!/usr/bin/env bash' \
        '{ printf "[%s]" "$@"; echo; } > "$DEVAGENT_TMP/seen-bats-argv"' \
        'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
# gnu = the real banner; bad = moreutils' `parallel` (no --version) — an absent
# binary takes the same branch (an empty banner).
_stub_gnu_parallel() { devagent_stub parallel 'GNU parallel 20231122'; }
_stub_bad_parallel() { devagent_stub parallel '' 1; }

@test "#593 suite_jobs: a non-integer config value dies loud BEFORE any suite runs" {
    _set_suite_jobs four
    _stub_bats_record_argv
    _run_rs
    [ ! -e "$DEVAGENT_TMP/seen-bats-argv" ]                       # bats never ran (negative leg first)
    [ -z "$(_art 2>/dev/null)" ]                                  # no artifact written
    [ "$status" -ne 0 ]
    [[ "$output" == *"suite_jobs must be a positive integer"* ]]
    [[ "$output" == *"[project.$TEST_PROJECT] suite_jobs"* ]]
}

@test "#593 suite_jobs: zero dies loud (1 is the serial floor)" {
    _set_suite_jobs 0
    _stub_bats_record_argv
    _run_rs
    [ ! -e "$DEVAGENT_TMP/seen-bats-argv" ]
    [ "$status" -ne 0 ]
    [[ "$output" == *"suite_jobs must be a positive integer"* ]]
}

@test "#593 suite_jobs: a bad DEVAGENT_SUITE_JOBS dies loud and names the env var" {
    _stub_bats_record_argv
    DEVAGENT_SUITE_JOBS=abc _run_rs
    [ ! -e "$DEVAGENT_TMP/seen-bats-argv" ]
    [ "$status" -ne 0 ]
    [[ "$output" == *"suite_jobs must be a positive integer"* ]]
    [[ "$output" == *"DEVAGENT_SUITE_JOBS"* ]]
}

@test "#593 suite_jobs=4 passes --jobs 4 --no-parallelize-within-files to bats" {
    _set_suite_jobs 4
    _stub_bats_record_argv
    _stub_gnu_parallel
    _run_rs
    [ "$status" -eq 0 ]
    devagent_assert_logged 'parallel --version'          # the probe ran, and accepted the banner
    seen="$(cat "$DEVAGENT_TMP/seen-bats-argv")"
    [[ "$seen" == *"[--jobs][4]"* ]]                     # two argv words, not one (see the stub)
    [[ "$seen" == *"[--no-parallelize-within-files]"* ]]
    [[ "$seen" == *"[--tap]"* ]]
}

@test "#593 BORN-RED control: with no suite_jobs, bats gets no --jobs at all" {
    # The mutation-proof for the test above: same stub, no key. If --jobs ever
    # appears here the flag is arriving from somewhere other than the config.
    # Green on both sides of the change by design (a CONTROL, not a born-red test).
    _stub_bats_record_argv
    _run_rs
    [ "$status" -eq 0 ]
    run grep -c -- '--jobs' "$DEVAGENT_TMP/seen-bats-argv"
    [ "$status" -eq 1 ]                                   # precise no-match (#337)
}

@test "#593 suite_jobs=1 explicitly is serial: no --jobs, no parallel probe" {
    # CONTROL (green on both sides): an explicit 1 must never touch `parallel`.
    _set_suite_jobs 1
    _stub_bats_record_argv
    _stub_bad_parallel                                    # would die if probed
    _run_rs
    [ "$status" -eq 0 ]
    devagent_refute_logged parallel                       # and the log proves it was never invoked
    run grep -c -- '--jobs' "$DEVAGENT_TMP/seen-bats-argv"
    [ "$status" -eq 1 ]
}

@test "#593 DEVAGENT_SUITE_JOBS=1 overrides a configured 4 (the A/B seam)" {
    # CONTROL (green on both sides): the override is what Task 7's serial runs use.
    _set_suite_jobs 4
    _stub_bats_record_argv
    _stub_bad_parallel                                    # would die if probed
    DEVAGENT_SUITE_JOBS=1 _run_rs
    [ "$status" -eq 0 ]
    devagent_refute_logged parallel
    run grep -c -- '--jobs' "$DEVAGENT_TMP/seen-bats-argv"
    [ "$status" -eq 1 ]
}

@test "#593 DEVAGENT_SUITE_JOBS=2 with no config key passes --jobs 2" {
    _stub_bats_record_argv
    _stub_gnu_parallel
    DEVAGENT_SUITE_JOBS=2 _run_rs
    [ "$status" -eq 0 ]
    [[ "$(cat "$DEVAGENT_TMP/seen-bats-argv")" == *"[--jobs][2]"* ]]
}

@test "#593 suite_jobs=4 with no GNU parallel dies loud, names the remedy, and never runs bats" {
    # moreutils' `parallel` is the real-world false positive for a bare
    # `command -v parallel`; a wholly absent binary takes the same branch (an
    # empty banner — tighten-verified). bats 1.10.0's own probe is miswired and
    # would instead let the run reach `parallel: command not found` inside the
    # TAP stream.
    _set_suite_jobs 4
    _stub_bats_record_argv
    _stub_bad_parallel
    _run_rs
    [ ! -e "$DEVAGENT_TMP/seen-bats-argv" ]                       # negative leg first
    [ -z "$(_art 2>/dev/null)" ]
    [ "$status" -ne 0 ]
    devagent_assert_logged 'parallel --version'          # the probe ran, and rejected the answer
    [[ "$output" == *"needs GNU parallel"* ]]
    [[ "$output" == *"suite_jobs = 1"* ]]
    [[ "$output" == *"DEVAGENT_SUITE_JOBS=1"* ]]
}

@test "#593 the suite child never sees DEVAGENT_SUITE_JOBS (the runner scrubs it, like the #240 pins)" {
    # The runner is invoked with the override set; a bats file that in turn invokes
    # run-suite.sh (this one) must not inherit it, or the env branch silently wins
    # over every config-driven assertion in the suite (Issue-565/578: the production
    # caller is the one that has to scrub). The stub is plain bash, so it sees
    # exactly what the runner passes.
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s" "${DEVAGENT_SUITE_JOBS-<UNSET>}" > "$DEVAGENT_TMP/seen-child-jobs"' \
        'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    DEVAGENT_SUITE_JOBS=1 _run_rs
    [ "$(cat "$DEVAGENT_TMP/seen-child-jobs")" = "<UNSET>" ]
    [ "$status" -eq 0 ]
}

@test "#593 the suite child never sees bats' own parallelism env (it would make bats_jobs FALSE)" {
    # bats reads all three of these from the ENVIRONMENT, not from argv
    # (bats-exec-suite:6,7,8), so without a scrub the operator's session decides the
    # mode while the artifact still reports suite_jobs. This is the serial leg, where
    # an inherited count is worst: no --no-parallelize-within-files goes on the command
    # line, so bats would also parallelise WITHIN files — the mode the #593 audit does
    # not cover — while `bats_jobs: 1` claims plain serial. BATS_PARALLEL_BINARY_NAME
    # defeats the probe rather than the artifact: bats would reach for a binary the
    # GNU-parallel banner check never looked at, and an absent one lands inside the TAP
    # stream as the "truncated suite" die — the misdiagnosis the probe exists to break.
    printf '%s\n' '#!/usr/bin/env bash' \
        '{ printf "j=%s " "${BATS_NUMBER_OF_PARALLEL_JOBS-<UNSET>}"' \
        '  printf "x=%s " "${BATS_NO_PARALLELIZE_ACROSS_FILES-<UNSET>}"' \
        '  printf "b=%s\n" "${BATS_PARALLEL_BINARY_NAME-<UNSET>}"' \
        '} > "$DEVAGENT_TMP/seen-child-bats-env"' \
        'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    BATS_NUMBER_OF_PARALLEL_JOBS=4 BATS_NO_PARALLELIZE_ACROSS_FILES=1 \
        BATS_PARALLEL_BINARY_NAME=rush _run_rs
    [ "$(cat "$DEVAGENT_TMP/seen-child-bats-env")" = "j=<UNSET> x=<UNSET> b=<UNSET>" ]
    [ "$status" -eq 0 ]
    grep -q '^bats_jobs: 1$' "$(_art)"
}

@test "#593 artifact: bats_jobs records the effective job count, appended after suite_env" {
    _set_suite_jobs 4
    _stub_bats_record_argv
    _stub_gnu_parallel
    _run_rs; [ "$status" -eq 0 ]
    art="$(_art)"
    grep -q '^bats_jobs: 4$' "$art"
    # Relative order, not an absolute line: the artifact's contract is "append
    # LAST", and the next line someone appends must not redden this test
    # (Issue-587). Prefix consumers are unmoved because bats: stays exactly one
    # line and `^bats:` cannot match `bats_jobs:`.
    [ "$(grep -n '^bats_jobs:' "$art" | cut -d: -f1)" -gt "$(grep -n '^suite_env:' "$art" | cut -d: -f1)" ]
    [ "$(grep -c '^bats:' "$art")" -eq 1 ]
    grep -q '^bats: 1/1 notok=0$' "$art"
}

@test "#593 artifact: a serial run records bats_jobs: 1" {
    _run_rs; [ "$status" -eq 0 ]                          # setup()'s default bats stub; no key, no override
    grep -q '^bats_jobs: 1$' "$(_art)"
}

@test "#593 artifact: DEVAGENT_SUITE_JOBS=2 is what gets recorded, not the config value" {
    _set_suite_jobs 4
    _stub_bats_record_argv
    _stub_gnu_parallel
    DEVAGENT_SUITE_JOBS=2 _run_rs
    [ "$status" -eq 0 ]
    grep -q '^bats_jobs: 2$' "$(_art)"
}

@test "#593 artifact: a tree with no bats suite records bats_jobs: (none)" {
    git rm -q tests/x.bats && git commit -q -m "no bats"
    _set_suite_jobs 4                                     # configured, but nothing to run
    _run_rs; [ "$status" -eq 0 ]
    grep -q '^bats: (none)$' "$(_art)"
    grep -q '^bats_jobs: (none)$' "$(_art)"
}

# --- #659: run-suite takes its ISSUE from the argument or the pin, never shared state ---
#
# The fixture's SHARED slot (devagent_test_setup) names Issue-1 in BOTH active_issue
# and issue_dir, and Issue-1 has a real directory, so "wrote into the slot's issue" is
# observable. Issue-2/Issue-3 are OTHER issues with real directories. Every #659 pin
# lives in THIS file, so one `bats --filter '#659'` run covers the mutation matrix
# (Issue-659 plan, t659-mutations.py).
_rs659()     { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$@"; }
_st659()     { printf '%s' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"; }
_issue659()  { mkdir -p "$DEVDOC_DIR/$1/analysis"; }
_arts659()   { find "$DEVDOC_DIR" -name '*-suite-count.txt' | wc -l; }
_empty659()  { [ -z "$(ls -A "$DEVDOC_DIR/$1/analysis" 2>/dev/null)" ]; }
_tag659()    { sed -n 's/^issue_unstated="\(.*\)"$/\1/p' "$DEVAGENT_ROOT/scripts/run-suite.sh"; }
_marker659() {   # a bats stub that leaves a marker, so "no suite ran" is observable
    printf '%s\n' '#!/usr/bin/env bash' 'touch "$DEVAGENT_TMP/bats-ran"' \
        'echo "1..3"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "not ok 3 c"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
_mr659() {       # an mr.md with an Evidence block, so preship-evidence reaches its artifact read
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 2/3 bats @ 0000000"; echo "files: 1 changed"; } > "$DEVDOC_DIR/$1/mr.md"
}
# ONE predicate for the AC3 sweep AND its planted controls (register Issue-585). An
# invocation is `run-suite.sh`, an optional quote or escape, whitespace, then a project
# placeholder; it passes when the next token is an issue. The quote class is a BRACKET
# on purpose: the `(\\?")?` spelling matched none of the quoted homes under GNU grep
# 3.0 (Issue-659 plan, U4: a dialect false negative, register Issue-106).
RS659_INV='run-suite\.sh[\\"]*[[:space:]]+(<project>|\$project)'
RS659_OK='run-suite\.sh[\\"]*[[:space:]]+(<project>|\$project)[[:space:]]+(<Issue-N>|\$[A-Za-z_{(])'
_rs659_inv()  { local rc=0; LC_ALL=C grep -rnHIE "$RS659_INV" "$@" || rc=$?; [ "$rc" -le 1 ] || return 2; }
_rs659_bare() { LC_ALL=C grep -vE "$RS659_OK" || true; }   # stdin: invocation lines; out: the bare ones

@test "#659 AC1/AC3: bare unpinned run-suite REFUSES while the shared slot names another issue; nothing runs or is written" {
    # The two-session shape: another session's pull left the SHARED slot on Issue-1
    # and this session named no issue. This is the BARE form itself (AC3).
    _marker659
    _rs659 "$TEST_PROJECT"
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]                                 # no suite ran
    [ "$(_arts659)" -eq 0 ]                                           # nothing written anywhere
    [ "$status" -eq 1 ]
    [ "$(_tag659)" = "ISSUE UNSTATED" ]                               # the tag, from the script
    [[ "$output" == *"ISSUE UNSTATED"* ]]
    [[ "$output" == *"'$DEVDOC_DIR/Issue-1'"* ]]                      # where it WOULD have written
    [[ "$output" == *"run-suite.sh\" $TEST_PROJECT <Issue-N>"* ]]     # the corrected command
    # Crossed with the overrides that decide NEIGHBOURING questions (register
    # Issue-597): neither guard's opt-out silences the issue refusal.
    DEVAGENT_SCOPE_GUARD_OVERRIDE=1 DEVAGENT_TREE_GUARD_OVERRIDE=1 _rs659 "$TEST_PROJECT"
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUE UNSTATED"* ]]
}

@test "#659 AC1/AC3: the #550 incident shape (active_issue empty, a STALE issue_dir) refuses too" {
    # Issue-550/actualWork.md:74-78: WSL state carried active_issue = "" and an
    # issue_dir still naming Issue-571; a bare run wrote Issue-550's artifact there.
    # Also excludes a fall-back to the shared active_issue or to the checklist scan
    # (Issue-1's checklist is incomplete, so a scan would pick it: matrix m1).
    devagent_state_set "$(_st659)" active_issue ""
    _marker659
    _rs659 "$TEST_PROJECT"
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUE UNSTATED"* ]]
    [[ "$output" == *"'$DEVDOC_DIR/Issue-1'"* ]]
}

@test "#659: an EMPTY shared slot (the post-cleanup state) refuses with the same tag" {
    # Before #659 this died "issue_dir not set or missing", also rc 1, so the TAG is
    # the assertion that can redden, not the rc (register Issue-Fork-132).
    devagent_state_set "$(_st659)" active_issue ""
    devagent_state_set "$(_st659)" issue_dir ""
    _marker659
    _rs659 "$TEST_PROJECT"
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUE UNSTATED"* ]]
    [[ "$output" == *"the shared slot is empty"* ]]
}

@test "#659: an UNPARSEABLE state file is named in the refusal, and nothing runs" {
    # state_get returns 2 for an unparseable file, and the refusal's read suppresses
    # state_get's own "needs repair" line, so the refusal itself names the file.
    printf '%s\n' 'this = = is not toml [' >> "$(_st659)"
    _marker659
    _rs659 "$TEST_PROJECT"
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUE UNSTATED"* ]]
    [[ "$output" == *"the state file is unparseable: $(_st659)"* ]]
}

@test "#659 AC1: the argument form writes into the ARGUMENT's issue while the shared slot names another" {
    _issue659 Issue-2
    _rs659 "$TEST_PROJECT" Issue-2
    _empty659 Issue-1                                                 # the slot's issue got nothing
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
    [[ "$output" == *"issue=Issue-2 from argument"* ]]                # the transcript names it
}

@test "#659 AC1: pinned-bare writes into the PIN's issue while the shared slot names another (control)" {
    # GREEN BEFORE AND AFTER #659 by design: the pin is session-local, so pinned-bare
    # stays legitimate (intent.md). If this reddens, the fix broke the pin.
    _issue659 Issue-2
    DEVAGENT_ACTIVE_ISSUE=Issue-2 _rs659 "$TEST_PROJECT"
    _empty659 Issue-1
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt
}

@test "#659: the argument beats the pin (the resolver's order, stated in the header)" {
    _issue659 Issue-2; _issue659 Issue-3
    DEVAGENT_ACTIVE_ISSUE=Issue-3 _rs659 "$TEST_PROJECT" Issue-2
    _empty659 Issue-3
    _empty659 Issue-1
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt
}

@test "#659 AC2: the measured tree comes from the RESOLVED issue, not the shared slot's worktree_path" {
    # The shared worktree_path belongs to Issue-1 (the shared active_issue); Issue-2
    # records none, so its tree is source_dir. A half-fix that took the DIRECTORY from
    # the argument but the TREE from the slot would stamp wt1 here (matrix m2).
    _issue659 Issue-2
    WT1="$DEVAGENT_TMP/wt1"
    git -C "$SOURCE_DIR" worktree add -q -b wt1-branch "$WT1" HEAD
    ( cd "$WT1" && git commit -q --allow-empty -m "wt1-only" )
    devagent_state_set "$(_st659)" worktree_path "$WT1"
    src_head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _rs659 "$TEST_PROJECT" Issue-2
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt)"
    grep -q "^head: $src_head " "$art"
    grep -q "^tree: $(cd "$SOURCE_DIR" && pwd -P)$" "$art"
}

@test "#659 AC2: the resolved issue's OWN recorded worktree_path is the tree measured" {
    _issue659 Issue-2
    WT2="$DEVAGENT_TMP/wt2"
    git -C "$SOURCE_DIR" worktree add -q -b wt2-branch "$WT2" HEAD
    ( cd "$WT2" && git commit -q --allow-empty -m "wt2-only" )
    wt2_head="$(git -C "$WT2" rev-parse HEAD)"
    devagent_state_set "$(_st659)" "context.Issue-2.worktree_path" "$WT2"
    _rs659 "$TEST_PROJECT" Issue-2
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt)"
    grep -q "^head: $wt2_head " "$art"
    grep -q "^tree: $(cd "$WT2" && pwd -P)$" "$art"
}

@test "#659: an invalid issue argument dies naming it, before any suite runs" {
    _marker659
    _rs659 "$TEST_PROJECT" 'Issue.2'
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Issue.2' is not a valid issue id"* ]]
}

@test "#659: an issue argument with no issue directory dies naming it and writes nothing" {
    _marker659
    _rs659 "$TEST_PROJECT" Issue-404
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ ! -e "$DEVDOC_DIR/Issue-404" ]                                  # the refusal created nothing
    [ "$(_arts659)" -eq 0 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"$DEVDOC_DIR/Issue-404"* ]]
}

@test "#659: both remedies the refusal prints, executed as printed, land in the named issue" {
    # Register Issue-594/Fork-132: run EVERY remedy the message prints (two), with the
    # <Issue-N> placeholder filled and a SPACED plugin root (Issue-597).
    _issue659 Issue-2; _issue659 Issue-3
    _rs659 "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    local arg_form pin_form
    arg_form="$(printf '%s\n' "$output" | sed -n 's/.*Name the issue: \(bash [^<]*<Issue-N>\).*/\1/p')"
    pin_form="$(printf '%s\n' "$output" | sed -n 's/.*(\(export DEVAGENT_ACTIVE_ISSUE=<Issue-N>\)).*/\1/p')"
    [ -n "$arg_form" ]
    [ -n "$pin_form" ]
    ln -s "$DEVAGENT_ROOT" "$DEVAGENT_TMP/plugin root"
    CLAUDE_PLUGIN_ROOT="$DEVAGENT_TMP/plugin root" PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run bash -c "${arg_form/<Issue-N>/Issue-2}"
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-2/analysis/"*-suite-count.txt
    PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run bash -c "${pin_form/<Issue-N>/Issue-3}; exec '$DEVAGENT_ROOT/scripts/run-suite.sh' '$TEST_PROJECT'"
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-3/analysis/"*-suite-count.txt
    _empty659 Issue-1
}

@test "#659: preship-evidence's no-artifact message prints run-suite WITH the issue, and that command runs" {
    _mr659 Issue-1
    run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT"   # bare: the shared slot's issue
    [ "$status" -eq 1 ]
    [[ "$output" == *"no suite-count artifact"* ]]
    local cmd
    cmd="$(printf '%s\n' "$output" | sed -n 's/.*run `\(bash [^`]*\)` at HEAD.*/\1/p')"
    [[ "$cmd" == *"run-suite.sh\" $TEST_PROJECT Issue-1" ]]
    ln -s "$DEVAGENT_ROOT" "$DEVAGENT_TMP/plugin root"
    CLAUDE_PLUGIN_ROOT="$DEVAGENT_TMP/plugin root" PATH="$DEVAGENT_TMP/binstub:$PATH" run bash -c "$cmd"
    [ "$status" -eq 0 ]
    ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT"
    [[ "$output" != *"no suite-count artifact"* ]]                    # the remedy cleared it
}

@test "#659 AC3 sweep: every documented run-suite invocation passes the issue" {
    # Subjects are DERIVED: every line under the shipped roots that invokes run-suite
    # with a project placeholder. They are never the issue's list of seven homes
    # (register Issue-458/461/583); the census found an eighth. CHANGELOG.md is
    # outside the roots, because its migration line quotes the retired form on
    # purpose. tests/ is outside too, except the one test that PRINTS a remedy to
    # the operator. Filesystem grep, not git grep: the matrix runs on a .git-less
    # copy (the Issue-566 tracked-set trade, stated).
    local ctl inv bad n r
    ctl="$DEVAGENT_TMP/ctl.md"
    printf '%s\n' 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-suite.sh" <project>   # x' \
                  'run-suite.sh\" $project <Issue-N>' \
                  'bash scripts/run-suite.sh <project> <Issue-N>' > "$ctl"
    inv="$(_rs659_inv "$ctl")"
    [ "$(printf '%s\n' "$inv" | grep -c .)" -eq 3 ]                   # all three are subjects
    bad="$(printf '%s\n' "$inv" | _rs659_bare)"
    [ "$(printf '%s\n' "$bad" | grep -c .)" -eq 1 ]                   # only the bare one trips
    [[ "$bad" == *'<project>   # x'* ]]
    local roots=(README.md CONTRIBUTING.md .github templates skills commands agents hooks
                 docs-site docs/specs scripts tests/locale-registration.bats)
    for r in "${roots[@]}"; do [ -e "$DEVAGENT_ROOT/$r" ] || { echo "missing root: $r"; return 1; }; done
    inv="$(cd "$DEVAGENT_ROOT" && _rs659_inv "${roots[@]}")" || { echo "grep failed over the roots"; return 1; }
    bad="$(printf '%s\n' "$inv" | _rs659_bare)"
    [ -z "$bad" ] || { echo "run-suite invoked without an issue:"; printf '%s\n' "$bad"; return 1; }
    n="$(printf '%s\n' "$inv" | grep -c .)"
    [ "$n" -ge 9 ] || { echo "only $n invocation lines (floor 9: the Task 1 census + the refusal)"; return 1; }
}

@test "#659 AC4: each evidence script's header states its issue precedence; the arity-asymmetry note is retired" {
    # Prose IS the subject here, so a text pin is right. It is matched over
    # comment-stripped, whitespace-normalised header text, so the prose may wrap
    # anywhere (register Issue-612/465).
    _hdr659() { awk '/^set -euo pipefail/{exit} {sub(/^#[ \t]*/, ""); print}' "$1" | tr -s '[:space:]' ' '; }   # [ \t]: mawk-safe
    local h old
    h="$(_hdr659 "$DEVAGENT_ROOT/scripts/run-suite.sh")"
    [[ "$h" == *"ISSUE PRECEDENCE (#659)"* ]]
    [[ "$h" == *"positional issue argument"* ]]
    [[ "$h" == *"argument wins"* ]]
    [[ "$h" == *"REFUSE with ISSUE UNSTATED"* ]]
    h="$(_hdr659 "$DEVAGENT_ROOT/scripts/preship-evidence.sh")"
    [[ "$h" == *"ISSUE PRECEDENCE (#659)"* ]]
    [[ "$h" == *"argument wins"* ]]
    [[ "$h" == *"SHARED per-project issue_dir slot"* ]]
    # Retired: the note blaming tree mismatches on run-suite taking no issue. Planted
    # control first: the retired line as it stood at dac0d78 (:198).
    old='run-suite without one'
    printf '%s\n' "#   with \$issue_arg; run-suite without one — see #571's plan)." | grep -qF "$old"
    [ "$(tr -s '[:space:]' ' ' < "$DEVAGENT_ROOT/scripts/preship-evidence.sh" | grep -cF "$old")" -eq 0 ]
}

@test "#659 AC4: preship-evidence's stated precedence is its behaviour (argument, then pin, then the shared slot)" {
    # Read through the no-artifact message, which names the resolved issue (Task 5).
    _issue659 Issue-2; _issue659 Issue-3
    _mr659 Issue-1; _mr659 Issue-2; _mr659 Issue-3
    DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-3
    [[ "$output" == *"run-suite.sh\" $TEST_PROJECT Issue-3\`"* ]]    # the argument beats the pin
    DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT"
    [[ "$output" == *"run-suite.sh\" $TEST_PROJECT Issue-2\`"* ]]    # the pin beats the slot
    run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT"
    [[ "$output" == *"run-suite.sh\" $TEST_PROJECT Issue-1\`"* ]]    # the shared slot, last
}

@test "#659: a wrong-PROJECT bare run still dies SCOPE MISMATCH first, not ISSUE UNSTATED (control)" {
    # The issue refusal sits AFTER active_guard_scope, so the more fundamental error is
    # named first: scope, then issue, then tree. GREEN BEFORE AND AFTER #659.
    devagent_fixture_projB
    _marker659
    _rs659                                   # no project: projB from the pointer; cwd is testproj
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"SCOPE MISMATCH"* ]]
    [[ "$output" != *"ISSUE UNSTATED"* ]]
}
