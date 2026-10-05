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
    # #660: preship-evidence checks the artifact's branch: against the issue's recorded
    # branch; SOURCE_DIR (devagent_test_setup) is on main.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch main
    mkdir -p "$DEVDOC_DIR/Issue-1/analysis"
}
teardown() { devagent_test_teardown; }

# #660: every artifact carries branch:/upstream: (preship-evidence fails one without
# them). These writers stay tree-less ON PURPOSE: the tree=unstamped back-compat
# shape, whose verdict tests/suite-tree-guard.bats pins.
# $1=head $2=dirty $3=bats-ok $4=plan $5=notok $6=passed $7=failed
_artifact() {
    printf 'head: %s  dirty: %s\nbats: %s/%s notok=%s\npytest: %s passed, %s failed\nbranch: main\nupstream: (no-origin)\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# $1=suite-line $2=files-n  (writes an mr.md with an Evidence block)
_mr() {
    { echo '## Summary'; echo 'x'; echo '## Evidence'
      echo "suite: $1"; echo "files: $2 changed"; } > "$DEVDOC_DIR/Issue-1/mr.md"
}
_run() { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1; }

# #677: step-13 analyzer lines in the Evidence block. _D is the newest date, _D1 the day
# before it. Fixture shapes mirror the real writers (analyze-shellcheck.sh,
# static_analysis_diff.py via analyze-static.sh, analyze-sanitizers.sh).
_D=2026-10-04
_D1=2026-10-03
_base677() {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
}
# _s13 <basename> <line>... - write a step-13 artifact, one argument per line.
_s13() { local b="$1"; shift; printf '%s\n' "$@" > "$DEVDOC_DIR/Issue-1/analysis/$b"; }
# _ev <line> - append a line to mr.md; _mr ends inside ## Evidence, so it lands there.
_ev() { printf '%s\n' "$1" >> "$DEVDOC_DIR/Issue-1/mr.md"; }
# _s13_sc <basename> <analyzer line> - a shellcheck-family artifact header.
_s13_sc() {
    _s13 "$1" '=== shellcheck (diff-scoped + untracked) ===' "date: $_D" 'baseline: 0000000' \
        "$2" 'scope: 0 file(s)' 'NEW findings: 0 (empty scope)'
}
# _s13_static <basename> <analyzer line> - the progress stream above the summary.
_s13_static() { _s13 "$1" 'Running cppcheck...' "$2" '' '## Static Analysis Summary'; }
# _s13_san <basename> <tag> [<extra line>...] - line 1 the tag, line 2 the stamp.
_s13_san() {
    local b="$1" t="$2"; shift 2
    _s13 "$b" "=== $t ===" "analyzer: $t GNU 99.1.0 (C)" \
        '-- The C compiler identification is GNU 99.1.0' '-- Configuring done' "$@"
}
# _cr_count <file> - how many CR bytes it holds, counted from od's text, never by a
# grep or sed over the CR-bearing file itself (Git Bash hides the CR from those).
_cr_count() {
    od -An -c "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i == "\\r") n++ } END { print n + 0 }'
}
# _fails - how many '  - ' failure entries the run reported.
_fails() { grep -c '^  - ' <<<"$output" || true; }

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
    printf 'head: %s  dirty: no\nbats: %s\npytest: %s\nbranch: main\nupstream: (no-origin)\n' "${3:-$HEAD_SHA}" "$1" "$2" \
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

@test "preship-evidence: a pre-#466 TWO-FIELD pytest line still parses (back-compat)" {
    # Artifacts written before the errors field exist on disk. The errors sed simply
    # finds nothing and defaults to 0 — an absent field must not read as a failure.
    _artifact_raw "285/285 notok=0" "20 passed, 0 failed"
    _mr "285/285 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence: a non-zero pytest ERROR count fails the suite-green check (#466 redmr)" {
    # An error is not a "failed", so this was invisible: `2 passed, 1 error` reconciled
    # green. bats has had the equivalent invariant since #406.
    _artifact_raw "285/285 notok=0" "2 passed, 0 failed, 1 errors"
    _mr "285/285 bats, 2 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -ne 0 ]
    [[ "$output" == *"errors=1"* ]]
}

@test "preship-evidence: a zero pytest ERROR count is still green (#466 redmr)" {
    _artifact_raw "285/285 notok=0" "2 passed, 0 failed, 0 errors"
    _mr "285/285 bats, 2 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

# #601: whitespace in a framework line must not decide the gate. Leading padding reads
# as the single-space form, a trailing blank after '(none)' fails loudly as unparseable,
# and a padded '(error)' is refused even with no Evidence block. The fixture greps are
# vacuity guards against a helper that trims its arguments. Declared blind spots:
# _artifact_raw always writes '<key>: ', so a parse needing exactly one literal space
# stays green; a trailing-blank '(error)' with no Evidence block is unparseable, which
# the #149 exit lets through with its WARN. Of the message tokens, only C/D's
# 'refusing to reconstruct' is mutation-proven; the others are belt-and-braces.

@test "preship-evidence: column-padded bats (none) and tab-padded pytest count reconcile pytest-only (#601)" {
    _artifact_raw "  (none)" $'\t158 passed, 0 failed, 0 errors'
    grep -q '^bats:   (none)$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    grep -q $'^pytest: \t158 passed' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "158 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"(158 pytest @ $HEAD_SHA; files=1)"* ]]
}

@test "preship-evidence: tab-padded bats count and column-padded pytest (none) reconcile bats-only (#601)" {
    _artifact_raw $'\t285/285 notok=0' "  (none)"
    grep -q $'^bats: \t285/285 notok=0$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    grep -q '^pytest:   (none)$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "285/285 bats @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"(285/285 bats @ $HEAD_SHA; files=1)"* ]]
}

@test "preship-evidence: trailing blank after bats (none) FAILS as unparseable, not silently absent (#601)" {
    # Paired with a real pytest count so the suite line itself MATCHES (bats adds no
    # part either way): the named verdict is then the only failure, and rc 1 is its alone.
    _artifact_raw "(none) " "158 passed, 0 failed, 0 errors"
    grep -q '^bats: (none) $' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "158 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'bats:' line"* ]]
    [[ "$output" == *"refusing to reconstruct"* ]]
    [[ "$output" != *"suite line mismatch"* ]]
}

@test "preship-evidence: trailing blank after pytest (none) FAILS as unparseable, not silently absent (#601)" {
    _artifact_raw "285/285 notok=0" "(none) "
    grep -q '^pytest: (none) $' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    _mr "285/285 bats @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'pytest:' line"* ]]
    [[ "$output" == *"refusing to reconstruct"* ]]
    [[ "$output" != *"suite line mismatch"* ]]
}

@test "preship-evidence: padded pytest (error) with NO Evidence block is still refused (#601)" {
    # Before #601 the early refusal above the #149 exit matched '^pytest: (error)$'
    # exactly, so this artifact exited 0 with the WARN while the main path refused it.
    _artifact_raw "285/285 notok=0" "  (error)"
    grep -q '^pytest:   (error)$' "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
    { echo '## Summary'; echo 'x'; } > "$DEVDOC_DIR/Issue-1/mr.md"   # no ## Evidence
    _run
    # The not-the-WARN leg comes FIRST, so a red E names the #149 WARN path directly.
    [[ "$output" != *"skipping evidence checks"* ]]
    [ "$status" -eq 1 ]
    [[ "$output" == *"(error)"* ]]
}

# #677: step 14 copies every counted analyzer: line of the newest step-13 artifacts into
# the Evidence block, whole; preship FAILS an unbacked or repeated one and WARNS (rc
# unchanged) about each one the block omits. One @test per leg, so each can redden alone.

@test "preship-evidence #677 (i): a copied shellcheck stamp passes with no omission warning" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.8.0'
    _ev 'analyzer: shellcheck 0.8.0'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"analyzer line omitted"* ]]
}

@test "preship-evidence #677 (ii): a retyped version fails as not backed, naming the counted line" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    _ev 'analyzer: shellcheck 0.11'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line not backed"* ]]
    [[ "$output" == *"'analyzer: shellcheck 0.11.0'"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (iii): a copied (version unknown) stamp passes" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck (version unknown)'
    _ev 'analyzer: shellcheck (version unknown)'
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (iv): a pre-#657 shellcheck artifact (no stamp) changes nothing" {
    _base677
    _run
    [ "$status" -eq 0 ]
    local before="$output"
    _s13 "$_D-shellcheck.txt" '=== shellcheck (diff-scoped + untracked) ===' "date: $_D" \
        'baseline: 0000000' 'scope: 0 file(s)' 'NEW findings: 0 (empty scope)'
    _run
    [ "$status" -eq 0 ]
    [ "$output" = "$before" ]
}

@test "preship-evidence #677 (v): an Evidence stamp with no step-13 artifact fails, none to copy" {
    _base677
    _ev 'analyzer: shellcheck 0.11.0'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"there are none to copy"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (vi-a): a probe file sorting after the real artifact is never selected" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    _s13 "$_D-t1-shellcheck.txt" 'analyzer: shellcheck 9.9.9-stub'
    _ev 'analyzer: shellcheck 9.9.9-stub'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line not backed"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (vi-b): beside a probe file, the real artifact's stamp passes" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    _s13 "$_D-t1-shellcheck.txt" 'analyzer: shellcheck 9.9.9-stub'
    _ev 'analyzer: shellcheck 0.11.0'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"analyzer line omitted"* ]]
}

@test "preship-evidence #677 (vii): a copied static stamp passes" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (viii-a): a CRLF artifact stamp matches an LF Evidence line" {
    _base677
    printf 'Running cppcheck...\nanalyzer: cppcheck 9.9.9-stub\r\n\n## Static Analysis Summary\n' \
        > "$DEVDOC_DIR/Issue-1/analysis/$_D-static.txt"
    [ "$(_cr_count "$DEVDOC_DIR/Issue-1/analysis/$_D-static.txt")" -eq 1 ]
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (viii-b): a CRLF Evidence line matches an LF artifact stamp" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    printf '%s\r\n' 'analyzer: cppcheck 9.9.9-stub' >> "$DEVDOC_DIR/Issue-1/mr.md"
    [ "$(_cr_count "$DEVDOC_DIR/Issue-1/mr.md")" -eq 1 ]
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (ix): an omitted stamp warns before an unchanged PASS line, rc 0" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 0 ]
    local pass="${lines[-1]}" last i w=-1
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Evidence analyzer line omitted"* ]]
    [[ "$output" == *"analyzer: cppcheck 9.9.9-stub"* ]]
    last=$(( ${#lines[@]} - 1 ))
    [ "${lines[$last]}" = "$pass" ]
    for i in "${!lines[@]}"; do
        if [[ "${lines[$i]}" == *"Evidence analyzer line omitted"* ]]; then w="$i"; fi
    done
    [ "$w" -ge 0 ]
    [ "$w" -lt "$last" ]
}

@test "preship-evidence #677 (x): an exact repeat fails as repeated" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line repeated"* ]]
    [[ "$output" == *"2 times"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (xi-a): static and sanitizer stamps both copied pass" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _s13_san "$_D-asan.txt" asan 'analyzer: stray'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: asan GNU 99.1.0 (C)'
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (xi-b): a sanitizer column-0 line past line 2 is not counted" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _s13_san "$_D-asan.txt" asan 'analyzer: stray'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: asan GNU 99.1.0 (C)'
    _ev 'analyzer: stray'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line not backed"* ]]
    [[ "$output" == *"'analyzer: cppcheck 9.9.9-stub', 'analyzer: asan GNU 99.1.0 (C)'"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (xi-c): the omitted static stamp is warned about beside a copied asan one" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _s13_san "$_D-asan.txt" asan 'analyzer: stray'
    _ev 'analyzer: asan GNU 99.1.0 (C)'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Evidence analyzer line omitted"*"analyzer: cppcheck 9.9.9-stub"* ]]
}

@test "preship-evidence #677 (xii-a): the newest is chosen per name, not across names" {
    _base677
    _s13_san "$_D1-asan.txt" asan
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: asan GNU 99.1.0 (C)'
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (xii-b): an older artifact's stamp is not backed" {
    _base677
    _s13_san "$_D1-asan.txt" asan
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _s13_static "$_D1-static.txt" 'analyzer: cppcheck 1.0.0-old'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: asan GNU 99.1.0 (C)'
    _ev 'analyzer: cppcheck 1.0.0-old'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line not backed: mr.md has 'analyzer: cppcheck 1.0.0-old'"* ]]
    [ "$(_fails)" -eq 1 ]
}

@test "preship-evidence #677 (xiii-a): the real analyze-shellcheck.sh stamp, copied, passes" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not on PATH: no real producer"
    _base677
    DEVAGENT_DATE_OVERRIDE=2026-07-10 run "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local line
    line="$(grep -x 'analyzer: shellcheck .*' "$DEVDOC_DIR/Issue-1/analysis/2026-07-10-shellcheck.txt")"
    [ -n "$line" ]
    _ev "$line"
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"analyzer line omitted"* ]]
}

@test "preship-evidence #677 (xiii-b): the real analyze-shellcheck.sh stamp, omitted, is warned about" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not on PATH: no real producer"
    _base677
    DEVAGENT_DATE_OVERRIDE=2026-07-10 run "$DEVAGENT_ROOT/scripts/analyze-shellcheck.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local line
    line="$(grep -x 'analyzer: shellcheck .*' "$DEVDOC_DIR/Issue-1/analysis/2026-07-10-shellcheck.txt")"
    [ -n "$line" ]
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Evidence analyzer line omitted"*"(or files:): $line"* ]]
}

@test "preship-evidence #677 (xiv): one stamp counted in two artifacts is warned about once" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: tsan GNU 99.1.0 (C)'
    _s13_san "$_D-tsan.txt" tsan
    _run
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Evidence analyzer line omitted' <<<"$output")" -eq 1 ]
}

@test "preship-evidence #677 (xv): the template's indented comment text is never counted" {
    _artifact "$HEAD_SHA" no 100 100 0 20 0
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    { echo '## Summary'; echo 'x'; echo '## Evidence'
      awk '/^## Evidence/{f=1;next} /^## /{f=0} f' "$DEVAGENT_ROOT/templates/mr_template.md" \
          | grep -v -e '^suite:' -e '^files:' -e '^platform:'
      echo "suite: 100/100 bats, 20 pytest @ $HEAD_SHA"; echo 'files: 1 changed'
      echo 'analyzer: shellcheck 0.11.0'; echo '## Checklist'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"not backed"* ]]
}

@test "preship-evidence #677 (xvi): a line both repeated and unbacked yields two entries" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    _ev 'analyzer: shellcheck 0.11'
    _ev 'analyzer: shellcheck 0.11'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Evidence analyzer line repeated"* ]]
    [[ "$output" == *"Evidence analyzer line not backed"* ]]
    [ "$(_fails)" -eq 2 ]
}

@test "preship-evidence #677 (R1): pasting the line the omission warning names clears it" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Paste it whole after platform: (or files:): "* ]]
    local line="${output#*Paste it whole after platform: (or files:): }"
    line="${line%%$'\n'*}"
    [ -n "$line" ]
    _ev "$line"
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"analyzer line omitted"* ]]
}

@test "preship-evidence #677 (R2): replacing the unbacked line with the named counted line clears it" {
    _base677
    _s13_sc "$_D-shellcheck.txt" 'analyzer: shellcheck 0.11.0'
    _ev 'analyzer: shellcheck 0.11'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"The counted lines are: '"* ]]
    local line="${output#*The counted lines are: \'}"
    line="${line%%\'*}"
    [ -n "$line" ]
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _ev "$line"
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (R3): deleting a stamp with none to copy clears it" {
    _base677
    _ev 'analyzer: shellcheck 0.11.0'
    _run
    [ "$status" -eq 1 ]
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _run
    [ "$status" -eq 0 ]
}

@test "preship-evidence #677 (R4): keeping one of a repeated stamp clears it" {
    _base677
    _s13_static "$_D-static.txt" 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 1 ]
    _mr "100/100 bats, 20 pytest @ $HEAD_SHA" 1
    _ev 'analyzer: cppcheck 9.9.9-stub'
    _run
    [ "$status" -eq 0 ]
}

@test "#677 pin (P1): the skill and the template carry the checker's step-13 regex and copy rule" {
    local re skill step4 tmpl block
    re="$(sed -n "s/^_s13_re='\(.*\)'\$/\1/p" "$DEVAGENT_ROOT/scripts/preship-evidence.sh")"
    [ -n "$re" ]
    skill="$(tr -s '[:space:]' ' ' < "$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md")"
    [[ "$skill" == *"$re"* ]]
    [[ "$skill" == *"line 2"* ]]
    [[ "$skill" == *'line 2 of an `asan`, `ubsan` or `tsan` one, if it starts `analyzer:`'* ]]
    [[ "$skill" == *"(version unknown)"* ]]
    [[ "$skill" == *"the suite run"* ]]
    step4="$(awk '/4[.] [*][*]Fill Testing section[.][*][*]/{f=1} /5[.] [*][*]Fill Checklist/{f=0} f' \
        "$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md" | tr -s '[:space:]' ' ')"
    [ -n "$step4" ]
    [[ "$step4" == *"counts only"* ]]
    [[ "$step4" == *"Evidence block"* ]]
    [[ "$step4" != *"<version>"* ]]
    tmpl="$(tr -s '[:space:]' ' ' < "$DEVAGENT_ROOT/templates/mr_template.md")"
    [[ "$tmpl" == *"$re"* ]]
    [[ "$tmpl" == *"line 2 of asan/ubsan/tsan if it starts analyzer:"* ]]
    block="$(awk '/^## Evidence/{f=1;next} /^## /{f=0} f' "$DEVAGENT_ROOT/templates/mr_template.md")"
    run grep -c '^analyzer:' <<<"$block"
    [ "$status" -eq 1 ]
    [ "$output" = 0 ]
    # Planted control: the same grep does count a column-0 line.
    run grep -c '^analyzer:' <<<'analyzer: x'
    [ "$output" = 1 ]
}

@test "#677 pin (P2): the verifier's step 4 and the checker header name the analyzer lines" {
    local p
    p="$(awk '/[*][*]Evidence cross-check[.][*][*]/{f=1} f && /[*][*]`TREE UNATTESTED`[*][*]/{exit} f' "$DEVAGENT_ROOT/agents/preship-verifier.md" | tr -s '[:space:]' ' ')"
    [ -n "$p" ]
    [[ "$p" == *"analyzer:"* ]]
    [[ "$p" == *"omitted"* ]]
    [[ "$p" == *"quote"* ]]
    grep -qF '#677 ANALYZER LINES (not a rung' "$DEVAGENT_ROOT/scripts/preship-evidence.sh"
}
