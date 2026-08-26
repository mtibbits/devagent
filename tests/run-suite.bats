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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^bats: 2/3 notok=1$' "$art"
    grep -q '^pytest: (none)$' "$art"           # no tests/test_*.py present
    grep -qE '^head: [0-9a-f]+  dirty: no$' "$art"
}

@test "run-suite records notok>0 on a failing tree (#359 AC)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q 'notok=1' "$art"
}

@test "run-suite dies loud when bats emits no plan line (#359)" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo "some error, no plan"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plan line"* ]]
}

@test "run-suite dies loud on a TRUNCATED run — plan present but ok+notok<plan (#406)" {
    # bats --tap emits 1..N first; a killed/crashed run leaves a full plan but
    # fewer ok/not-ok lines. Stub that shape: plan 5, only 3 ok, 0 not ok.
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..5"' 'echo "ok 1 a"' 'echo "ok 2 b"' 'echo "ok 3 c"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 51 passed, 0 failed, 0 errors$' "$art"
}

@test "run-suite parses a mixed failed+passed pytest summary (order-independent)" {
    echo 'def test_ok(): pass' > tests/test_stub.py
    git add -A && git commit -q -m "add py test"
    _stub_python3_pytest "3 failed, 282 passed in 0.02s"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q '^pytest: 282 passed, 3 failed, 0 errors$' "$art"
}

@test "run-suite artifact name honors DEVAGENT_DATE_OVERRIDE (#413/#338)" {
    export DEVAGENT_DATE_OVERRIDE=2020-02-02
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/2020-02-02-suite-count.txt" ]
}

@test "#571 AC3: the head:/dirty: stamp survives, and the artifact records its tree" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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

@test "#571 AC5: the core-draft-mr skill's documented caller shape still works" {
    # The EXACT argv shape skills/core-draft-mr/SKILL.md:66 carries at HEAD:
    #     bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-suite.sh" <project>
    # (read from the file at implementation time; #572 made the project explicit.
    # Running a VARIANT of a published command is not running it — register Issue-106.)
    PATH="$DEVAGENT_TMP/binstub:$PATH" run bash "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
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
        run env -u LC_ALL -u LC_CTYPE -u LANG "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
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
_run_rs() { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"; }

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
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q "^python: $DEVAGENT_TMP/elsewhere/python$" "$(_art)"
}

@test "run-suite: python: is (none) for a tree with no pytest suite (#466 redmr)" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q '^python: (none)$' "$(_art)"
}
