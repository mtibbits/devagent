#!/usr/bin/env bats
# #359 preship-evidence.sh — verification #4. Reads mr.md + suite-count artifact +
# git; no bats/pytest execution, so no nesting concern.
load 'helpers/common'

# Baseline = the seed commit; add one more commit so baseline..HEAD has changes.
setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    echo one > f1.txt && git add -A && git commit -q -m one
    BASELINE="$(git rev-parse HEAD)"
    echo two > f2.txt && git add -A && git commit -q -m two   # 1 file changed vs baseline
    HEAD_SHA="$(git rev-parse HEAD)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASELINE"
    mkdir -p "$DEVDOC_DIR/Issue-1/analysis"
}
teardown() { devagent_test_teardown; }

# $1=head $2=dirty $3=bats-ok $4=plan $5=notok $6=passed $7=failed
_artifact() {
    printf 'head: %s  dirty: %s\nbats: %s/%s notok=%s\npytest: %s passed, %s failed\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# $1=suite-line $2=files-n  (writes an mr.md with an Evidence block)
_mr() {
    { echo '## Summary'; echo 'x'; echo '## Evidence'
      echo "suite: $1"; echo "files: $2 changed"; } > "$DEVDOC_DIR/Issue-1/mr.md"
}
_run() { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1; }

@test "preship-evidence: matching Evidence → rc 0 (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: suite count off by one → nonzero naming both (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "101/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"101/100"* ]] && [[ "$output" == *"100/100"* ]]
}

@test "preship-evidence: stale head → nonzero (#359)" {
    _artifact "deadbeefdeadbeef" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ deadbeefdeadbeef" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"head"* ]]
}

@test "preship-evidence: dirty tree → nonzero (#359)" {
    _artifact "$HEAD_SHA" yes 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"dirty"* ]]
}

@test "preship-evidence: TRUNCATED run (ok<plan, notok=0) → nonzero naming truncation (#406)" {
    # A killed bats run: 500 of 992 ran, 0 failures — looks green, isn't.
    _artifact "$HEAD_SHA" no 500 992 0 20 0
    _mr "500/992 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"truncated"* ]]
    [[ "$output" == *"500 of 992"* ]]
}

@test "preship-evidence: legit-failing run (notok>0) is NOT mislabeled truncated (#406)" {
    # ok<plan because a test FAILED, not because the run was cut short — the notok
    # check reports it; the truncation assert (gated on notok==0) must stay silent.
    _artifact "$HEAD_SHA" no 99 100 1 20 0
    _mr "99/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"notok"* ]]
    [[ "$output" != *"truncated"* ]]
}

@test "preship-evidence: notok>0 → nonzero (#359)" {
    _artifact "$HEAD_SHA" no 99 100 1 20 0
    _mr "99/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"notok"* ]]
}

@test "preship-evidence: files count mismatch → nonzero (#359)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 7   # actual is 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"files"* ]]
}

@test "preship-evidence: unset baseline_sha → die (#359)" {
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha ""
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"baseline"* ]]
}

@test "preship-evidence: mr.md with no Evidence block → warn + rc 0 (#359 back-compat)" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

# $1=head  → writes a no-framework (neither bats nor pytest) suite-count artifact.
# Delegates to _artifact_raw (defined below) so the artifact's printf template has ONE
# home in this file: #571 added a tree: line to the format and had to touch every
# writer, and a missed one leaves a test passing against a format nothing emits.
_artifact_none() { _artifact_raw "(none)" "(none)" "$1"; }

@test "preship-evidence: no-framework project reconciles 'suite: none' → rc 0 (#411)" {
    _artifact_none "$HEAD_SHA"
    _mr "none @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: no-framework artifact vs a bats-style Evidence line → nonzero, names 'none @' (#411)" {
    _artifact_none "$HEAD_SHA"
    _mr "0/0 bats, 0 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"none @"* ]]
}

@test "preship-evidence: end-to-end no-framework (run-suite → preship) clean (#411)" {
    # SOURCE_DIR has no tests/*.bats or tests/test_*.py → run-suite writes (none)/(none).
    run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^bats: (none)$'   "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    grep -q '^pytest: (none)$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "none @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

# #466: write the two framework lines VERBATIM, so single-framework and error
# artifacts are expressible. $1=bats-line-body $2=pytest-line-body $3=head (opt)
_artifact_raw() {
    printf 'head: %s  dirty: no\nbats: %s\npytest: %s\n' "${3:-$HEAD_SHA}" "$1" "$2" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}

@test "preship-evidence: bats-only artifact reconciles '<n>/<m> bats @ sha' (#466)" {
    _artifact_raw "285/285 notok=0" "(none)"
    _mr "285/285 bats @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: bats-only REJECTS the legacy ', 0 pytest' false green (#572 MINOR-5)" {
    # "0 pytest" reads as a measured zero; the framework is ABSENT. Different facts.
    _artifact_raw "285/285 notok=0" "(none)"
    _mr "285/285 bats, 0 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"285/285 bats @ $HEAD_SHA"* ]]   # names the correct line
}

@test "preship-evidence: pytest-only artifact reconciles '<k> pytest @ sha' (#466)" {
    _artifact_raw "(none)" "51 passed, 0 failed"
    _mr "51 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: pytest: (error) FAILS and does not suppress a second failure (#466)" {
    # The (error) verdict is a fails+= entry, NOT a die: this script's contract is to
    # accumulate and report every failure at once. A die would hand the operator one
    # failure per round-trip. Pair it with a stale head so the report must name BOTH.
    _artifact_raw "285/285 notok=0" "(error)" "deadbeefdeadbeef"
    _mr "285/285 bats @ deadbeefdeadbeef" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"(error)"* ]]
    [[ "$output" == *"head"* ]]
}

@test "preship-evidence: unparseable bats: line FAILS without emitting '/ bats' (#466)" {
    _artifact_raw "garbage" "(none)"
    _mr "anything @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" != *"/ bats"* ]]
}

@test "#466 sweep: every documentation home of the suite: format carries the single-framework forms" {
    # The bats-only and pytest-only forms are what #466 introduces. Assert each home
    # separately and by an ANCHORED pattern: a bare 'pytest @ <sha>' grep is satisfied
    # by the pre-existing BOTH-frameworks form, so that leg could never redden
    # (register Issue-151/Issue-337 — a vacuous presence guard).
    local f
    for f in "$DEVAGENT_ROOT/templates/mr_template.md" \
             "$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md" \
             "$DEVAGENT_ROOT/agents/preship-verifier.md"; do
        [ "$(grep -cE 'bats @ <(head-)?sha>' "$f")" -ge 1 ] \
            || { echo "no bats-only form in $f"; return 1; }
        # The pytest-only form is a 'pytest @ <sha>' that is NOT the tail of the
        # both-frameworks form, whose distinguishing token is the 'bats,' separator.
        # Deliberately no bracket expression: '[^a-z]' is collation-dependent, so an
        # anchored character-class version returned a different count under LC_ALL than
        # under the ambient locale (register Issue-106 — running a VARIANT of a command
        # is not running it). This pins the CLAIM, not one phrasing of it.
        [ "$(grep -E 'pytest @ <(head-)?sha>' "$f" | grep -vc 'bats,')" -ge 1 ] \
            || { echo "no pytest-only form in $f"; return 1; }
    done
}

@test "preship-evidence: (error) refuses even with NO Evidence block — the gate is not bypassable (#466 review MAJOR-2)" {
    # Deleting the Evidence block used to skip the (error) refusal entirely, because
    # the #149 back-compat exit runs before the artifact is ever read — while four
    # homes claimed the gate could not be bypassed. An unenforced measurement is not a
    # control (register lawFirm Issue-14).
    _artifact_raw "285/285 notok=0" "(error)"
    { echo '## Summary'; echo 'x'; } > "$DEVDOC_DIR/Issue-1/mr.md"   # no ## Evidence
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"(error)"* ]]
}

@test "preship-evidence: a no-Evidence mr.md with a MEASURED artifact still passes (#149 back-compat)" {
    # The MAJOR-2 fix must not swallow the #149 rule it sits above: a legacy issue with
    # no Evidence block stays shippable when the suite was actually measured.
    _artifact_raw "285/285 notok=0" "20 passed, 0 failed"
    { echo '## Summary'; echo 'x'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: a no-Evidence mr.md with NO artifact at all still passes (#149 back-compat)" {
    # The early check must not turn "no artifact" into a failure — that is the #149
    # path proper, and the early glob is guarded on non-empty for exactly this reason.
    rm -f "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    { echo '## Summary'; echo 'x'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: an unparseable bats: line is REPORTED, not silently dropped (#466 review MINOR-1)" {
    # The prior test asserted only rc!=0 and the absence of "/ bats" — both satisfied
    # by the suite-line mismatch alone, so deleting the fails+= verdict left the suite
    # green (mutation-proven in review). Pin the verdict itself: with a real pytest
    # count beside it, dropping the verdict reconstructs a copyable "51 pytest @ <sha>"
    # and a bats suite whose counts could not be read vanishes from the Evidence.
    _artifact_raw "garbage" "51 passed, 0 failed"
    _mr "51 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to reconstruct"* ]]
    [[ "$output" == *"bats:"* ]]
}

@test "preship-evidence: an unparseable pytest: line is REPORTED, not silently dropped (#466 review MINOR-1)" {
    # Mirror of the above — this leg had no test at all.
    _artifact_raw "285/285 notok=0" "garbage"
    _mr "285/285 bats @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to reconstruct"* ]]
    [[ "$output" == *"pytest:"* ]]
}
