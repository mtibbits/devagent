#!/usr/bin/env bats
# #362 born-red mechanizer (design: Issue-333/designs/m1-born-red-mechanizer.md).
#
# NOTE on the `bats` stub: bats-core cannot run nested inside a bats run (a nested
# invocation selects 0 tests regardless of env / env -i / setsid — the harness
# detects nesting). born-red.sh runs `bats` internally, so the bats-classification
# ACs drive it with a deterministic TAP stub keyed to a head-only marker; the
# worktree lifecycle, detection, artifact, verdict and commit gate are all still
# exercised for real. Real-bats integration end-to-end is covered by the pytest AC
# (pytest does NOT have the nesting limitation) plus the out-of-bats smoke check.
load 'helpers/common'

# Build a baseline in SOURCE_DIR: a product lib whose answer is WRONG at baseline
# (so a test of the right answer is red there) plus a tests/ dir, committed.
# Enable born_red and record baseline_sha in state.
setup() {
    devagent_test_setup
    python3 - "$HOME/.claude/devagent/config.toml" "$TEST_PROJECT" <<'PY'
import sys, re
path, proj = sys.argv[1:]
t = open(path).read()
t = re.sub(rf'(\[project\.{re.escape(proj)}\]\n)', r'\1born_red = true\n', t, count=1)
open(path,'w').write(t)
PY
    cd "$SOURCE_DIR" || return
    mkdir -p tests
    echo 'answer() { echo 0; }' > lib.sh          # baseline: WRONG answer
    git add -A && git commit -q -m "baseline"
    BASELINE="$(git rev-parse HEAD)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE"
    # HEAD (working tree): fix the product so a correct test is GREEN at HEAD.
    echo 'answer() { echo 42; }' > lib.sh
    # Deterministic `bats` stub: feature.bats → RED at baseline / GREEN at HEAD
    # (keyed on .born_red_head, present only in the source tree, never overlaid to
    # the baseline worktree); any other test file → GREEN everywhere (vacuous).
    mkdir -p "$DEVAGENT_TMP/binstub"
    cat > "$DEVAGENT_TMP/binstub/bats" <<'STUB'
#!/usr/bin/env bash
file=""; for a in "$@"; do file="$a"; done   # last positional = the test file
names="$(grep -oE '@test "[^"]*"' "$file" 2>/dev/null | sed 's/^@test "//; s/"$//')"
[ -n "$names" ] || names="t"
# feature.bats: GREEN only at HEAD (marker present); anything else: GREEN everywhere.
green=1
case "$file" in *feature.bats) [ -e ./.born_red_head ] || green=0 ;; esac
printf '1..%s\n' "$(printf '%s\n' "$names" | grep -c .)"
i=0
while IFS= read -r nm; do
  i=$((i+1))
  if [ "$green" = 1 ]; then echo "ok $i $nm"; else echo "not ok $i $nm"; fi
done <<EON
$names
EON
STUB
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    touch "$SOURCE_DIR/.born_red_head"
}
teardown() { devagent_test_teardown; }

_run_br() { run "$DEVAGENT_ROOT/scripts/born-red.sh" "$TEST_PROJECT"; }
# Same, but with the deterministic bats stub shadowing real bats on PATH.
_run_br_stub() { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/born-red.sh" "$TEST_PROJECT"; }
_artifact() { ls "$DEVDOC_DIR/Issue-1/analysis/"*-born-red.txt 2>/dev/null; }

# NB: the `@test` lines below are emitted via printf, NOT written as column-0
# heredoc lines — bats's line-based preprocessor rewrites any `^@test "…"` line in
# THIS file (including inside a heredoc) into `test_…() { bats_test_begin … }`,
# which would make these helpers write the pre-processed form.
_add_real_test() {   # red at baseline (answer=0), green at HEAD (answer=42)
    { echo '#!/usr/bin/env bats'
      echo 'setup() { source "${BATS_TEST_DIRNAME}/../lib.sh"; }'
      printf '%s\n' '@test "answer is 42" { [ "$(answer)" = 42 ]; }'
    } > "$SOURCE_DIR/tests/feature.bats"
}
_add_vacuous_test() {   # green at baseline (never red)
    { echo '#!/usr/bin/env bats'
      printf '%s\n' '@test "always true" { true; }'
    } > "$SOURCE_DIR/tests/vacuous.bats"
}

@test "born-red: new failing-at-baseline file → PASS, exit 0 (#362 AC1)" {
    _add_real_test
    _run_br_stub
    [ "$status" -eq 0 ]
    grep -q '^verdict: PASS$' "$(_artifact)"
    grep -q 'baseline=RED' "$(_artifact)"
    grep -q 'head=GREEN' "$(_artifact)"
}

@test "born-red: new green-at-baseline test → FLAGGED, nonzero, names it (#362 AC2)" {
    _add_vacuous_test
    _run_br_stub
    [ "$status" -ne 0 ]
    grep -q '^verdict: FLAGGED' "$(_artifact)"
    grep -Fq 'vacuous.bats :: "always true" | baseline=GREEN' "$(_artifact)"
}

@test "born-red: allowlist + reason → GREEN-ALLOWED / PASS (#362 AC3)" {
    _add_vacuous_test
    printf '%s\n' 'tests/vacuous.bats :: always true — characterization test, feature pre-exists' \
        > "$DEVDOC_DIR/Issue-1/.devagent-born-red-allow"
    _run_br_stub
    [ "$status" -eq 0 ]
    grep -q '^verdict: PASS (1 allowed-green)$' "$(_artifact)"
    grep -Fq 'baseline=GREEN-ALLOWED (characterization' "$(_artifact)"
}

@test "born-red: a reasonless allowlist row dies (#362 AC3)" {
    _add_vacuous_test
    printf '%s\n' 'tests/vacuous.bats :: always true' > "$DEVDOC_DIR/Issue-1/.devagent-born-red-allow"
    _run_br_stub
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason"* || "$output" == *"— <reason>"* ]]
}

@test "born-red: knob off → exit 0, no artifact (#362 AC6)" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.born_red" false
    _add_vacuous_test
    _run_br
    [ "$status" -eq 0 ]
    [ -z "$(_artifact)" ]
}

@test "born-red: knob on + no baseline_sha → die, no artifact (#362 AC7)" {
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha ""
    _add_real_test
    _run_br
    [ "$status" -ne 0 ]
    [ -z "$(_artifact)" ]
}

@test "born-red: zero new tests → NO-NEW-TESTS, exit 0 (#362 AC8)" {
    _run_br   # working tree has no tests/ delta vs baseline
    [ "$status" -eq 0 ]
    grep -q '^verdict: NO-NEW-TESTS$' "$(_artifact)"
}

@test "born-red: empty name-filter match dies (bats 1..0 exits 0) (#362 AC9)" {
    # The -f name path needs a MODIFIED file (present at baseline, added block in
    # the working tree). Commit a seed test, re-point baseline at it, then add a
    # block. A stubbed bats emits an empty TAP plan (1..0, exit 0) — born-red must
    # die on the plan, not the exit code.
    printf '#!/usr/bin/env bats\n@test "seed" { true; }\n' > "$SOURCE_DIR/tests/mod.bats"
    ( cd "$SOURCE_DIR" && git add tests/mod.bats && git commit -q -m "seed test" )
    local nb; nb="$( git -C "$SOURCE_DIR" rev-parse HEAD )"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$nb"
    printf '@test "new block" { true; }\n' >> "$SOURCE_DIR/tests/mod.bats"
    mkdir -p "$DEVAGENT_TMP/binstub"
    printf '#!/usr/bin/env bash\necho "1..0"\n' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/born-red.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ZERO tests"* ]]
}

@test "born-red: operator tree byte-identical before and after (#362 AC5)" {
    _add_real_test
    local before after
    before="$( cd "$SOURCE_DIR" && git status --porcelain; git -C "$SOURCE_DIR" rev-parse HEAD )"
    _run_br_stub
    [ "$status" -eq 0 ]
    after="$( cd "$SOURCE_DIR" && git status --porcelain; git -C "$SOURCE_DIR" rev-parse HEAD )"
    [ "$before" = "$after" ]
    # No stray worktrees left registered.
    run bash -c "cd '$SOURCE_DIR' && git worktree list | wc -l"
    [ "$output" -eq 1 ]
}

@test "born-red: pytest parity — new failing-at-baseline py file → PASS (#362 AC10)" {
    if ! python3 -m pytest --version >/dev/null 2>&1; then skip "pytest absent"; fi
    cat > "$SOURCE_DIR/tests/test_feature.py" <<'EOF'
import subprocess, pathlib
def test_answer():
    lib = pathlib.Path(__file__).parent.parent / "lib.sh"
    out = subprocess.check_output(["bash","-c",f"source {lib}; answer"]).decode().strip()
    assert out == "42"
EOF
    _run_br
    [ "$status" -eq 0 ]
    grep -q '^verdict: PASS$' "$(_artifact)"
    grep -q 'test_feature.py' "$(_artifact)"
}

@test "born-red: new zero-@test whole file → NO-NEW-TESTS, not PASS (#407)" {
    # A NEW .bats file that bats loads to an empty plan (1..0, exit 0). Without the
    # fix the whole-file unit contributes zero rows and the run falls through to a
    # PASS verdict / "new tests: 0"; the fix demands NO-NEW-TESTS.
    printf '#!/usr/bin/env bats\n# no @test blocks here\n' > "$SOURCE_DIR/tests/empty.bats"
    printf '#!/usr/bin/env bash\necho "1..0"\n' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/born-red.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q '^verdict: NO-NEW-TESTS$' "$(_artifact)"
}

@test "born-red: new whole file that fails to load (no TAP plan) → die (#407)" {
    # bats load failure: an error line, NO 1..N plan, nonzero exit swallowed by the
    # else branch's `|| true`. Without the fix this yields zero rows → silent PASS.
    printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$SOURCE_DIR/tests/loadfail.bats"
    printf '#!/usr/bin/env bash\necho "Error: could not load test file" >&2\nexit 1\n' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/born-red.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to load"* ]]
}
