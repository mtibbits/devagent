#!/usr/bin/env bats
# bats file_tags=gitbash
# #1122 claims-check.sh — the read-only claims half of the preship preflight. It reads
# mr.md, git and (for pytest counts) a collection, and reports stale claims; it never
# writes. Every test asserts the exact rc, the intended message and the per-kind summary
# (register Issue-337/151/32), and pairs each refusal with a same-token survivor.
load 'helpers/common'
bats_require_minimum_version 1.5.0

# Baseline = the seed commit plus one; HEAD is one commit (one file) past it.
setup() {
    devagent_test_setup
    unset DEVAGENT_PYTEST_PYTHON PYTHONDONTWRITEBYTECODE DEVAGENT_COLLECT_TIMEOUT   # Issue-565/578
    cd "$SOURCE_DIR" || return
    echo one > f1.txt && git add -A && git commit -q -s -m one
    BASELINE="$(git rev-parse HEAD)"
    echo two > f2.txt && git add -A && git commit -q -s -m two
    HEAD_SHA="$(git rev-parse HEAD)"
    ST="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    devagent_state_set "$ST" baseline_sha "$BASELINE"
    devagent_state_set "$ST" branch main
    mkdir -p "$DEVDOC_DIR/Issue-1/analysis"
}
teardown() { devagent_test_teardown; }

MR() { printf '%s\n' "$DEVDOC_DIR/Issue-1/mr.md"; }
# _body <line>... - write mr.md, one argument per line.
_body() { printf '%s\n' "$@" > "$(MR)"; }
# _cc [args...] - run the checker with stdout and stderr apart.
_cc() { run --separate-stderr "$DEVAGENT_ROOT/scripts/claims-check.sh" "$@"; }
_ccr() { _cc "$TEST_PROJECT" Issue-1; }
# _summary - the last stdout line.
_summary() { tail -n 1 <<<"$output"; }
# _sum <bats> <pytest> <total> <commit> <files> <cited> <signoff> <mismatched> <notchecked>
_sum() {
    printf 'claims-check: checked %s (bats-count %s, pytest-count %s, suite-total %s, commit-count %s, files-count %s, cited-commit %s, signoff %s); %s mismatched; %s not checked' \
        "$(( $1 + $2 + $3 + $4 + $5 + $6 + $7 ))" "$@"
}
ZERO_SUM="claims-check: checked 0 (bats-count 0, pytest-count 0, suite-total 0, commit-count 0, files-count 0, cited-commit 0, signoff 0); 0 mismatched; 0 not checked"
# _gitshim <subcommand> <rc> [<argv text>] - DEVAGENT_GIT logs every call (argv and
# GIT_NO_LAZY_FETCH) to $GITLOG, exits <rc> when the first non-option word is
# <subcommand> (and argv holds <argv text>, when given), else runs git.
_gitshim() {
    GITLOG="$DEVAGENT_TMP/git.log"; : > "$GITLOG"
    local real; real="$(command -v git)"
    cat > "$DEVAGENT_TMP/gitshim" <<EOF
#!/usr/bin/env bash
printf 'NLF=%s %s\n' "\${GIT_NO_LAZY_FETCH-unset}" "\$*" >> '$GITLOG'
a=("\$@"); i=0
while [ "\$i" -lt "\${#a[@]}" ]; do case "\${a[\$i]}" in -C) i=\$((i + 2)) ;; -*) i=\$((i + 1)) ;; *) break ;; esac; done
if [ "\${a[\$i]-}" = '$1' ]; then case "\$*" in *'${3-}'*) exit $2 ;; esac; fi
exec '$real' "\$@"
EOF
    chmod +x "$DEVAGENT_TMP/gitshim"
    export DEVAGENT_GIT="$DEVAGENT_TMP/gitshim"
}

# ---- Task 4: arguments, resolution, exits, the summary ------------------------------

@test "usage: zero or three args, or any -* option → 2, stdout empty" {
    _body 'nothing here'
    _cc
    [ "$status" -eq 2 ]; [ -z "$output" ]; [[ "$stderr" == *"usage: claims-check.sh <project> <Issue-N>"* ]]
    _cc "$TEST_PROJECT" Issue-1 extra
    [ "$status" -eq 2 ]; [ -z "$output" ]; [[ "$stderr" == *"usage: claims-check.sh <project> <Issue-N>"* ]]
    _cc "$TEST_PROJECT" Issue-1 --attestable-exit
    [ "$status" -eq 2 ]; [ -z "$output" ]; [[ "$stderr" == *"unknown option '--attestable-exit'"* ]]
    _cc -h
    [ "$status" -eq 2 ]; [ -z "$output" ]
    _ccr                                                        # the survivor: two args
    [ "$status" -eq 0 ]; [ "$(_summary)" = "$ZERO_SUM" ]
}

@test "ISSUE UNSTATED → 2, not 1, with the exit trap armed" {
    _body 'nothing here'
    unset DEVAGENT_ACTIVE_ISSUE
    _cc "$TEST_PROJECT"
    [ "$status" -eq 2 ]; [ -z "$output" ]
    [[ "$stderr" == *"ISSUE UNSTATED"* ]]
    [[ "$stderr" != *"COULD NOT RUN"* ]]                        # the trap was disarmed, not fired
    DEVAGENT_ACTIVE_ISSUE=Issue-1 _cc "$TEST_PROJECT"           # the pin states it
    [ "$status" -eq 0 ]; [ "$(_summary)" = "$ZERO_SUM" ]
}

@test "no mr.md → 1, COULD NOT RUN, stdout empty" {
    rm -f "$(MR)"
    _ccr
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"claims-check: COULD NOT RUN — no mr.md at $(MR)"* ]]
}

@test "no baseline_sha → 1" {
    _body 'nothing here'
    sed -i '/^baseline_sha/d' "$ST"
    _ccr
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"claims-check: COULD NOT RUN — no baseline_sha recorded for Issue-1"* ]]
}

@test "git failure (shim exits 3 on ls-tree) → 1" {
    _body 'nothing here'
    _gitshim ls-tree 3
    _ccr
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"claims-check: COULD NOT RUN — git ls-tree"* ]]
    _gitshim no-such-subcommand 3                              # the survivor: the same shim, passing
    _ccr
    [ "$status" -eq 0 ]; [ "$(_summary)" = "$ZERO_SUM" ]
    grep -q ' ls-tree -r -z --name-only HEAD$' "$GITLOG"
}

@test "a die after the guards → 1" {
    _body 'nothing here'
    devagent_state_set "$ST" worktree_path "$DEVAGENT_TMP/no-such-tree"
    _ccr
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"recorded worktree_path is not a usable git tree"* ]]
    [[ "$stderr" == *"claims-check: COULD NOT RUN"* ]]
}

@test "no recognised claim → 0, exact 'checked 0 (… all 0)'" {
    _body '## Summary' 'Fixes the widget. No counts here.' '## Testing' 'Ran it by hand.'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    [ "$output" = "$ZERO_SUM" ]
    [ -z "$stderr" ]
}

# ---- Task 5: bats per-file counts, at-commit, untrusted input; the scanner -----------
# _tests <path> <n> - write a bats file with <n> @test blocks into the tree (uncommitted).
_tests() {
    local f="$SOURCE_DIR/$1" i
    mkdir -p "$(dirname "$f")"
    { echo '#!/usr/bin/env bats'; for ((i = 1; i <= $2; i++)); do printf '@test "t%s" {\n  true\n}\n' "$i"; done; } > "$f"
}
_commit() { git -C "$SOURCE_DIR" add -A && git -C "$SOURCE_DIR" commit -q -s -m "$1"; }
_head() { git -C "$SOURCE_DIR" rev-parse HEAD; }
# _has <fixed text> - stdout holds it.
_has() { grep -qF -- "$1" <<<"$output" || { echo "missing: $1"; echo "$output"; return 1; }; }
_hasnt() { ! grep -qF -- "$1" <<<"$output" || { echo "unexpected: $1"; echo "$output"; return 1; }; }

@test "#1101 case: (26 tests) vs 27 @test → 3" {
    _tests tests/x.bats 27; _commit x
    _body '## Testing' '- `tests/x.bats` (26 tests) — the new cases.'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:2: MISMATCH bats-count: `tests/x.bats` (26 tests) — claimed 26, found 27 (at HEAD)'
    [ "$(_summary)" = "$(_sum 1 0 0 0 0 0 0 1 0)" ]
    _body '## Testing' '- `tests/x.bats` (27 tests) — the new cases.'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    [ "$output" = "$(_sum 1 0 0 0 0 0 0 0 0)" ]
}

@test "each of the 14 recorded bats forms reports a stale count" {
    _tests tests/f.bats 5; _commit f
    local forms=('`tests/f.bats` 4/4' '`tests/f.bats` → 4/4' '`tests/f.bats` (4 tests)' '`tests/f.bats`: 4/4'
                 '`tests/f.bats` — 4 tests' '`tests/f.bats` passes 4/4' '`tests/f.bats`: 4 tests' '`tests/f.bats` 4 ok'
                 '`tests/f.bats` — 4/4' '`tests/f.bats` passed 4/4' '`tests/f.bats` pass 4/4' '`tests/f.bats`: 4 ok'
                 '`tests/f.bats` → 4 ok' '4 tests in `tests/f.bats`') i
    _body "${forms[@]/#/- }"
    _ccr
    [ "$status" -eq 3 ]
    for i in "${!forms[@]}"; do
        grep -qE "^mr\.md:$((i + 1)): MISMATCH bats-count: .* — claimed 4, found 5 \(at HEAD\)$" <<<"$output" \
            || { echo "form $((i + 1)) not reported: ${forms[$i]}"; echo "$output"; return 1; }
    done
    [ "$(_summary)" = "$(_sum 14 0 0 0 0 0 0 14 0)" ]
}

@test "the three PowerShell forms are NOT CHECKED" {
    _body '- `tests/A.Tests.ps1` 4/4' '- `tests/A.Tests.ps1`: 4/4' '- `tests/A.Tests.ps1`: 4 passed' '- `foo_test.go` (5 tests)'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has 'mr.md:1: NOT CHECKED test-count: `tests/A.Tests.ps1` 4/4 — another framework'
    _has 'mr.md:2: NOT CHECKED test-count: `tests/A.Tests.ps1`: 4/4 — another framework'
    _has 'mr.md:3: NOT CHECKED test-count: `tests/A.Tests.ps1`: 4 passed — another framework'
    _has 'mr.md:4: NOT CHECKED test-count: `foo_test.go` (5 tests) — another framework'
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 4)" ]
}

@test "bare (N), (N new) and (+N) after a path are not claims" {
    _tests tests/f.bats 5; _commit f
    _body '- `tests/f.bats` (4)' '- `tests/f.bats` (4 new tests)' '- `tests/f.bats` (4 new)' '- `tests/f.bats` (+4)'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body '- `tests/f.bats` (4 tests)'                          # the survivor
    _ccr
    [ "$status" -eq 3 ]; [ "$(_summary)" = "$(_sum 1 0 0 0 0 0 0 1 0)" ]
}

@test "a file:line citation is not a count (T3)" {
    _tests tests/f.bats 5; _commit f
    _body 'See `pull.bats:134/153` and `tests/f.bats`:12 and tests/f.bats:3/4.'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body 'See `tests/f.bats`: 4/4.'                             # colon then a space: a count
    _ccr
    [ "$status" -eq 3 ]; _has 'claimed 4, found 5 (at HEAD)'
}

@test "two files with the same count text on one line are attributed per file" {
    _tests tests/f.bats 5; _tests tests/g.bats 6; _commit fg
    _body '- `tests/f.bats` (5 tests), `tests/g.bats` (5 tests)'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH bats-count: `tests/g.bats` (5 tests) — claimed 5, found 6 (at HEAD)'
    _hasnt 'tests/f.bats'
    [ "$(_summary)" = "$(_sum 2 0 0 0 0 0 0 1 0)" ]
}

@test "an emphasis-wrapped claim is recognised" {
    _tests tests/f.bats 5; _commit f
    _body '- **`tests/f.bats` (4 tests)**' '- `tests/f.bats` **(4 tests)**' '- __`tests/f.bats` → 4/4__'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH bats-count:'; _has 'mr.md:2: MISMATCH bats-count:'; _has 'mr.md:3: MISMATCH bats-count:'
    [ "$(_summary)" = "$(_sum 3 0 0 0 0 0 0 3 0)" ]
}

@test "an underscore pair inside a path keeps its name" {
    _tests tests/__x__.bats 5; _commit x
    _body '- `tests/__x__.bats` (4 tests)' '- __x__.bats: 4/4'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH bats-count: `tests/__x__.bats` (4 tests) — claimed 4, found 5 (at HEAD)'
    _has 'mr.md:2: MISMATCH bats-count: __x__.bats: 4/4 — claimed 4, found 5 (at HEAD)'
}

@test "26 tests at <sha>: compared at that commit" {
    _tests tests/f.bats 26; _commit f26; local old; old="$(_head)"
    _tests tests/f.bats 27; _commit f27
    _body "- \`tests/f.bats\` (26 tests) at ${old:0:7}"
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 1 0 0 0 0 1 0 0 0)" ]       # the sha is also cited (Task 9)
    _body "- \`tests/f.bats\` (25 tests) at ${old:0:7}"
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH bats-count: \`tests/f.bats\` (25 tests) — claimed 25, found 26 (at ${old:0:12})"
    _body "- At \`$old\`, \`tests/f.bats\` (25 tests)"           # At qualifies (T7)
    _ccr
    [ "$status" -eq 3 ]; _has "claimed 25, found 26 (at ${old:0:12})"
    _body "- \`tests/f.bats\` (26 tests), format ${old:0:7}"      # format <sha> does not
    _ccr
    [ "$status" -eq 3 ]; _has 'claimed 26, found 27 (at HEAD)'
}

@test "at-commit token edges" {
    _tests tests/f.bats 26; _commit f26; local old; old="$(_head)"
    _tests tests/f.bats 27; _commit f27
    _body '- `tests/f.bats` (26 tests) at HEAD.' "- \`tests/f.bats\` (25 tests) at ${old:0:7}." \
          '- `tests/f.bats` (26 tests) at the tip' '- `tests/f.bats` (26 tests), at the final SHA'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH bats-count: `tests/f.bats` (26 tests) — claimed 26, found 27 (at HEAD)'
    _has "mr.md:2: MISMATCH bats-count: \`tests/f.bats\` (25 tests) — claimed 25, found 26 (at ${old:0:12})"
    _has 'mr.md:3: MISMATCH bats-count: `tests/f.bats` (26 tests) — claimed 26, found 27 (at HEAD)'
    _has 'mr.md:4: MISMATCH bats-count: `tests/f.bats` (26 tests) — claimed 26, found 27 (at HEAD)'
}

@test "a count at a sha that resolves to no single local commit is NOT CHECKED" {
    _tests tests/f.bats 5; _commit f
    _body '- `tests/f.bats` (4 tests) at deadbee' '- `tests/f.bats` (4 tests) at the old run'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has 'mr.md:1: NOT CHECKED bats-count: `tests/f.bats` (4 tests) — deadbee resolves to no single local commit'
    _has 'mr.md:2: NOT CHECKED bats-count: `tests/f.bats` (4 tests) — measured at the'
    _has 'mr.md:1: NOT CHECKED cited-commit: deadbee — deadbee resolves to no single local commit'   # Task 9
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 3)" ]
}

@test "a file absent at the at-commit → NOT CHECKED \"absent at <sha12>\"" {
    _tests tests/f.bats 5; _commit f
    _body "- \`tests/f.bats\` (4 tests) at ${BASELINE:0:9}"
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has "mr.md:1: NOT CHECKED bats-count: \`tests/f.bats\` (4 tests) — absent at ${BASELINE:0:12}"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 1 0 0 1)" ]                         # the sha is also cited (Task 9)
}

@test "a failed rev-parse other than rc 1 (shim rc 3) → 1" {
    _tests tests/f.bats 5; _commit f
    _body "- \`tests/f.bats\` (4 tests) at ${BASELINE:0:9}"
    _gitshim rev-parse 3 "${BASELINE:0:9}^{commit}"
    _ccr
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"claims-check: COULD NOT RUN — git rev-parse ${BASELINE:0:9}"* ]]
}

@test "untrusted paths never reach git" {
    _tests tests/f.bats 5; _commit f; _tests tests/u.bats 5           # u.bats is untracked
    _body '- `../outside/x.bats` (4 tests)' '- `/tmp/outside/x.bats` (4 tests)' '- `tests/u.bats` (4 tests)' \
          '- `-rf.bats` (4 tests)' "- \`$SOURCE_DIR/tests/f.bats\` (4 tests)" '- `./tests/f.bats` (4 tests)'
    _gitshim no-such-subcommand 3
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: NOT CHECKED bats-count: \`../outside/x.bats\` (4 tests) — path refused (contains ..)"
    _has "mr.md:2: NOT CHECKED bats-count: \`/tmp/outside/x.bats\` (4 tests) — path refused (absolute, outside the tree)"
    _has "mr.md:3: NOT CHECKED bats-count: \`tests/u.bats\` (4 tests) — not tracked at HEAD"
    _has "mr.md:4: NOT CHECKED bats-count: \`-rf.bats\` (4 tests) — path refused (leading -)"
    _has "mr.md:5: MISMATCH bats-count:"; _has "mr.md:6: MISMATCH bats-count:"     # the survivors
    [ "$(_summary)" = "$(_sum 2 0 0 0 0 0 0 2 4)" ]
    run grep -qE 'outside|u\.bats|-rf' "$GITLOG"; [ "$status" -eq 1 ]   # SC2314: never a bare !
    grep -qF ':tests/f.bats' "$GITLOG"                                       # the selector sees paths
}

@test "a joint count is NOT CHECKED" {
    _tests tests/f.bats 10; _tests tests/g.bats 10; _commit fg
    _body '- `tests/f.bats`, `tests/g.bats` (20 tests)' '- `tests/f.bats` `tests/g.bats` → 20/20'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has 'mr.md:1: NOT CHECKED bats-count: `tests/g.bats` (20 tests) — count for several files'
    _has 'mr.md:2: NOT CHECKED bats-count: `tests/g.bats` → 20/20 — count for several files'
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 2)" ]
}

@test "a unique basename resolves; an ambiguous one is NOT CHECKED" {
    _tests tests/f.bats 5; _tests tests/a/h.bats 5; _tests tests/b/h.bats 5; _commit fh
    _body '- `f.bats` (4 tests)' '- `h.bats` (4 tests)'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH bats-count: `f.bats` (4 tests) — claimed 4, found 5 (at HEAD)'
    _has 'mr.md:2: NOT CHECKED bats-count: `h.bats` (4 tests) — ambiguous basename (2 tracked files)'
}

@test "F4 has a left boundary (A8)" {
    _tests tests/f.bats 5; _commit f
    _body '- 1,234 tests in `tests/f.bats`' '- #4 tests in `tests/f.bats`'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body '- ran 4 tests in `tests/f.bats`'                       # the survivor
    _ccr
    [ "$status" -eq 3 ]; _has 'mr.md:1: MISMATCH bats-count: 4 tests in `tests/f.bats` — claimed 4, found 5 (at HEAD)'
}

@test "A4 as measured, documented miss; earlier and partial words" {
    # imPlan-potentialFutureEnhancements.md "A4 word boundaries": the earlier/partial
    # words match as case-sensitive SUBSTRINGS before the count, the path included, so a
    # path holding "baseline" reads as an earlier run. A deliberate miss, never a report.
    _tests tests/rebaseline.bats 5; _tests tests/f.bats 5; _commit rf
    _body '- `tests/rebaseline.bats` (4 tests)' '- run before the fix: `tests/f.bats` (4 tests)' \
          '- bats -k foo `tests/f.bats` (4 tests)' '- only `tests/f.bats` (4 tests)'
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has "mr.md:1: NOT CHECKED bats-count: \`tests/rebaseline.bats\` (4 tests) — an earlier run ('baseline')"
    _has "mr.md:2: NOT CHECKED bats-count: \`tests/f.bats\` (4 tests) — an earlier run ('before')"
    _has "mr.md:3: NOT CHECKED bats-count: \`tests/f.bats\` (4 tests) — a partial run ('-k ')"
    _has "mr.md:4: NOT CHECKED bats-count: \`tests/f.bats\` (4 tests) — a partial run ('only ')"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 4)" ]
    _body '- Before the fix `tests/f.bats` (4 tests)'               # case-sensitive, as measured (A4)
    _ccr
    [ "$status" -eq 3 ]; _has 'mr.md:1: MISMATCH bats-count:'
}

@test "no engine drift: the claim regexes run under bash =~ only" {
    # Issue-106: running a variant of a published regex under another engine is not
    # running it. No grep -E / egrep / sed -E in the script; the @test predicate is
    # spelled once.
    run bash -c "grep -v '^[[:space:]]*#' '$DEVAGENT_ROOT/scripts/claims-check.sh' | grep -nE 'grep -[A-Za-z]*E|egrep|sed -[A-Za-z]*E|awk'"
    [ "$status" -eq 1 ]
    run bash -c "printf 'x | grep -E y\n' | grep -nE 'grep -[A-Za-z]*E|egrep|sed -[A-Za-z]*E|awk'"   # planted control
    [ "$status" -eq 0 ]
    [ "$(grep -cF "'^[[:blank:]]*@test[[:blank:]]'" "$DEVAGENT_ROOT/scripts/claims-check.sh")" -eq 1 ]
}

@test "nothing inside ## Evidence is reported" {
    _tests tests/f.bats 5; _commit f
    _body '## Summary' 'x' '## Evidence' '- `tests/f.bats` (4 tests)' "suite: 9/9 bats @ $HEAD_SHA" 'files: 99 changed' \
          '0123456789abcdef0123456789abcdef01234567' '## Notes' '- `tests/f.bats` (4 tests)'
    _ccr
    [ "$status" -eq 3 ]
    _hasnt 'mr.md:4:'; _hasnt 'mr.md:7:'
    _has 'mr.md:9: MISMATCH bats-count:'                       # the same line after the block
    [ "$(_summary)" = "$(_sum 1 0 0 0 0 0 0 1 0)" ]
    # Controls (Tasks 8 and 9): the bogus 40-hex and the files: line, outside the block, are read.
    _body '- 0123456789abcdef0123456789abcdef01234567' "suite: 9/9 bats @ $HEAD_SHA" '- 99 files changed'
    _ccr
    _has 'mr.md:1: NOT CHECKED cited-commit: 0123456789abcdef0123456789abcdef01234567'
    _has "mr.md:2: NOT CHECKED suite-total: 9/9 bats — measured at $HEAD_SHA"
    _has 'mr.md:3: MISMATCH files-count: 99 files changed'
}

@test "fenced and commented lines are not scanned" {
    _tests tests/f.bats 5; _commit f
    _body '```' '`tests/f.bats` (4 tests)' '```' '~~~' '```' '`tests/f.bats` (4 tests)' '~~~' \
          '<!-- `tests/f.bats` (4 tests) -->' '<!--' '`tests/f.bats` (4 tests)' '-->' \
          'x <!-- `tests/f.bats` (3 tests) --> `tests/f.bats` (4 tests)'
    _ccr
    [ "$status" -eq 3 ]
    [ "$(grep -c '^mr\.md:' <<<"$output")" -eq 1 ]
    _has 'mr.md:12: MISMATCH bats-count: `tests/f.bats` (4 tests) — claimed 4, found 5 (at HEAD)'
}

@test "CRLF scans like LF" {
    _tests tests/f.bats 5; _commit f
    _body '## Testing' '- `tests/f.bats` (4 tests)' '- `tests/f.bats`: 5/5' '```' '`tests/f.bats` (3 tests)' '```'
    _ccr
    local lf="$output" lfrc="$status"
    sed -i 's/$/\r/' "$(MR)"
    [ "$(od -c "$(MR)" | grep -c '\\r')" -ge 1 ]               # the CRs are there
    _ccr
    [ "$status" -eq "$lfrc" ]; [ "$output" = "$lf" ]
    [ "$(_summary)" = "$(_sum 2 0 0 0 0 0 0 1 0)" ]
}

# ---- Task 6: pytest counts (U6) -------------------------------------------------------
# _pystub <path> - a pytest stand-in. It logs argv, PYTHONDONTWRITEBYTECODE and the session
# pin to $PYLOG; --version exits 0; --collect-only prints $PYOUT and exits $PYRC (or
# sleeps $PYSLEEP first).
_pystub() {
    PYLOG="$DEVAGENT_TMP/py.log"; PYOUT="$DEVAGENT_TMP/py.out"; : > "$PYLOG"
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s|PDWB=%s|PIN=%s\n' "\$*" "\${PYTHONDONTWRITEBYTECODE-unset}" "\${DEVAGENT_ACTIVE_ISSUE-unset}" >> '$PYLOG'
case "\$*" in
  *--collect-only*) [ -z "\${PYSLEEP:-}" ] || exec sleep "\$PYSLEEP"; cat '$PYOUT'; exit "\${PYRC:-0}" ;;
  *--version*) echo 'pytest 9.0.0'; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$1"
    printf '%s\n' 'tests/test_p.py::test_a[1]' 'tests/test_p.py::test_a[2]' 'tests/test_p.py::test_a[3]' \
        'tests/test_p.py::test_b' '' '4 tests collected in 0.01s' > "$PYOUT"
}
# _pyart [<python: value>] - the newest suite-count artifact, its python: line written as
# run-suite writes it (`python: <interp>`); no argument writes no python: line.
_pyart() {
    { printf 'head: %s  dirty: no\nbats: 0/0 notok=0\npytest: 4 passed, 0 failed\n' "$(_head)"
      [ "$#" -eq 0 ] || printf 'python: %s\n' "$1"; } > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
# _py_fixture - tests/test_p.py and tests/test_a__b.py tracked; the stub as the tree's
# .venv/bin/python (excluded, so the tree stays clean); the artifact records it.
_py_fixture() {
    mkdir -p "$SOURCE_DIR/tests"
    printf 'def test_b():\n    pass\n' > "$SOURCE_DIR/tests/test_p.py"
    cp "$SOURCE_DIR/tests/test_p.py" "$SOURCE_DIR/tests/test_a__b.py"
    _commit p
    echo '.venv/' >> "$SOURCE_DIR/.git/info/exclude"
    VENV_PY="$SOURCE_DIR/.venv/bin/python"; _pystub "$VENV_PY"; _pyart "$VENV_PY"
}
_collections() { grep -c -- '--collect-only' "$PYLOG" || true; }

@test "a parametrized file counts once per case" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests)' '- `tests/test_a__b.py` (3 tests)'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH pytest-count: `tests/test_p.py` (3 tests) — claimed 3, found 4 (at HEAD)'
    _has 'mr.md:2: MISMATCH pytest-count: `tests/test_a__b.py` (3 tests) — claimed 3, found 4 (at HEAD)'
    [ "$(_summary)" = "$(_sum 0 2 0 0 0 0 0 2 0)" ]
    grep -qF -- '--collect-only -q ./tests/test_a__b.py|' "$PYLOG"           # the name survived the scan
}

@test "each of the 7 recorded pytest forms reports a stale count" {
    _py_fixture
    local forms=('`tests/test_p.py`: 3 passed' '`tests/test_p.py` 3/3' '`tests/test_p.py` (3 tests)' '`tests/test_p.py` 3 passed'
                 '`tests/test_p.py`: 3/3' '`tests/test_p.py`: 3 tests' '`tests/test_p.py` passes 3/3') i
    _body "${forms[@]/#/- }"
    _ccr
    [ "$status" -eq 3 ]
    for i in "${!forms[@]}"; do
        grep -qE "^mr\.md:$((i + 1)): MISMATCH pytest-count: .* — claimed 3, found 4 \(at HEAD\)$" <<<"$output" \
            || { echo "form $((i + 1)) not reported: ${forms[$i]}"; echo "$output"; return 1; }
    done
    [ "$(_summary)" = "$(_sum 0 7 0 0 0 0 0 7 0)" ]
    [ "$(_collections)" -eq 1 ]                                          # one collection per path
}

# _real_pytest - DEVAGENT_PYTEST_PYTHON = an interpreter that can run pytest, or skip.
_real_pytest() {
    local py; py="$(command -v python3 || true)"
    [ -n "$py" ] && "$py" -m pytest --version >/dev/null 2>&1 || skip "pytest not available"
    export DEVAGENT_PYTEST_PYTHON="$py"
    mkdir -p "$SOURCE_DIR/tests"
    printf '%s\n' 'import pytest' '' '@pytest.mark.parametrize("x", [1, 2, 3])' 'def test_a(x):' '    assert x' '' \
        'def test_b():' '    pass' > "$SOURCE_DIR/tests/test_real.py"
    _commit real
    _pyart "$py"
}

@test "real pytest, parametrized (skip if pytest absent)" {
    _real_pytest
    _body '- `tests/test_real.py` (4 tests)'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 1 0 0 0 0 0 0 0)" ]
    _body '- `tests/test_real.py` (2 tests)'
    _ccr
    [ "$status" -eq 3 ]; _has 'mr.md:1: MISMATCH pytest-count: `tests/test_real.py` (2 tests) — claimed 2, found 4 (at HEAD)'
}

@test "real pytest with addopts = -q → NOT CHECKED \"collection output not parseable\" (skip if pytest absent)" {
    _real_pytest
    printf '[pytest]\naddopts = -q\n' > "$SOURCE_DIR/pytest.ini"; _commit ini; _pyart "$DEVAGENT_PYTEST_PYTHON"
    _body '- `tests/test_real.py` (2 tests)'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_real.py` (2 tests) — collection output not parseable'
}

@test "a pytest count naming a commit is NOT CHECKED, including at HEAD" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests) at HEAD' "- \`tests/test_p.py\` (4 tests) at ${BASELINE:0:7}" \
          "- \`tests/test_p.py\` (3 tests) at the tip"
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — measured at HEAD'
    _has "mr.md:2: NOT CHECKED pytest-count: \`tests/test_p.py\` (4 tests) — measured at ${BASELINE:0:7}"
    _has 'mr.md:3: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — measured at HEAD'
    [ "$(_collections)" -eq 0 ]
}

@test "the resolver probe runs with PYTHONDONTWRITEBYTECODE=1" {
    _py_fixture
    [ -z "${PYTHONDONTWRITEBYTECODE+x}" ]                                   # unset in the parent
    _body '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 3 ]; _has 'claimed 3, found 4 (at HEAD)'               # and the claim is compared
    grep -qF -- '-m pytest --version|PDWB=1|' "$PYLOG"
    grep -qF -- '--collect-only -q ./tests/test_p.py|PDWB=1|' "$PYLOG"
}

@test "python: (none) or no python: line → NOT CHECKED, stub never invoked" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests)'
    _pyart '(none)'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — suite run recorded no interpreter'
    _pyart
    _ccr
    [ "$status" -eq 0 ]; _has 'suite run recorded no interpreter'
    rm "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"              # no artifact at all
    _ccr
    [ "$status" -eq 0 ]; _has 'suite run recorded no interpreter'
    [ ! -s "$PYLOG" ]
}

@test "an interpreter recorded on another host → NOT CHECKED naming both values" {
    _py_fixture
    _pyart /home/other/proj/.venv/bin/python
    _body '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 0 ]
    _has "mr.md:1: NOT CHECKED pytest-count: \`tests/test_p.py\` (3 tests) — interpreter differs from the suite run's: /home/other/proj/.venv/bin/python vs $VENV_PY"
    [ "$(_collections)" -eq 0 ]
}

@test "an override spelled differently (<dir>//python vs <dir>/python) → NOT CHECKED" {
    _py_fixture
    _pystub "$DEVAGENT_TMP/py/python"
    export DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/py//python"
    _pyart "$DEVAGENT_TMP/py/python"
    _body '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 0 ]
    _has "interpreter differs from the suite run's: $DEVAGENT_TMP/py/python vs $DEVAGENT_TMP/py//python"
    export DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/py/python"                   # the same spelling: compared
    _ccr
    [ "$status" -eq 3 ]; _has 'claimed 3, found 4 (at HEAD)'
}

@test "no pytest claim → resolver never called" {
    _py_fixture; _tests tests/f.bats 5; _commit f
    _body '- `tests/f.bats` (4 tests)'
    _ccr
    [ "$status" -eq 3 ]
    [ ! -s "$PYLOG" ]
    _body '- `tests/f.bats` (4 tests)' '- `tests/test_p.py` (3 tests)'          # the survivor: one pytest claim
    _ccr
    [ "$status" -eq 3 ]
    grep -qF -- '-m pytest --version' "$PYLOG"
}

@test "dirty tree → NOT CHECKED" {
    _py_fixture
    echo 'x = 1' >> "$SOURCE_DIR/tests/test_p.py"
    _body '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — dirty tree'
    [ "$(_collections)" -eq 0 ]
}

@test "collection exit 2 → NOT CHECKED" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests)'
    PYRC=2 _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — collection failed (exit 2)'
    printf '\nno tests ran in 0.01s\n' > "$PYOUT"
    PYRC=5 _ccr                                                             # rc 5: found 0
    [ "$status" -eq 3 ]; _has 'claimed 3, found 0 (at HEAD)'
}

@test "unparseable collection (only 'file: N', rc 0) → NOT CHECKED \"collection output not parseable\"" {
    _py_fixture
    printf 'tests/test_p.py: 4\n' > "$PYOUT"
    _body '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — collection output not parseable'
    printf '%s\n' 'tests/test_p.py::test_a' '' '2 tests collected in 0.01s' > "$PYOUT"   # ids and summary disagree
    _ccr
    [ "$status" -eq 0 ]; _has 'collection output not parseable'
}

@test "collection that sleeps past DEVAGENT_COLLECT_TIMEOUT=1 → NOT CHECKED \"collection timed out\"" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests)'
    PYSLEEP=5 DEVAGENT_COLLECT_TIMEOUT=1 _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `tests/test_p.py` (3 tests) — collection timed out'
    DEVAGENT_COLLECT_TIMEOUT=0 _ccr                                          # an invalid bound dies
    [ "$status" -eq 1 ]; [ -z "$output" ]
    [[ "$stderr" == *"DEVAGENT_COLLECT_TIMEOUT must be a positive integer"* ]]
}

@test "DEVAGENT_PYTEST_PYTHON set to a non-executable → NOT CHECKED \"override not executable\"; other reports still print, rc 3 not 1" {
    _py_fixture; _tests tests/f.bats 5; _commit f
    export DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/no-such-python"
    _side
    _body '- `tests/test_p.py` (3 tests)' '- `tests/f.bats` (4 tests)' '- On this branch: 9 commits.' "- From \`${SIDE:0:9}\`."
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$HEAD_SHA"
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: NOT CHECKED pytest-count: \`tests/test_p.py\` (3 tests) — override not executable: $DEVAGENT_TMP/no-such-python"
    _has 'mr.md:2: MISMATCH bats-count: `tests/f.bats` (4 tests) — claimed 4, found 5 (at HEAD)'
    _has 'mr.md:3: MISMATCH commit-count: 9 commits'; _has 'mr.md:4: MISMATCH cited-commit:'
    [ "$(_summary)" = "$(_sum 1 0 0 1 0 1 0 3 1)" ]
}

@test "stub argv holds ./<tracked path> and no other mr.md token" {
    _py_fixture
    _body '- `tests/test_p.py` (3 tests) -- --rootdir=/etc'
    _ccr
    [ "$status" -eq 3 ]
    [ "$(grep -- '--collect-only' "$PYLOG" | cut -d'|' -f1)" = "-m pytest -p no:cacheprovider --collect-only -q ./tests/test_p.py" ]
}

@test "an outside, an untracked and a -leading test_*.py path are NOT CHECKED and absent from the stub's argv log" {
    _py_fixture
    printf 'def test_u():\n    pass\n' > "$SOURCE_DIR/tests/test_u.py"; echo 'tests/test_u.py' >> "$SOURCE_DIR/.git/info/exclude"
    _body '- `../x/test_o.py` (3 tests)' '- `tests/test_u.py` (3 tests)' '- `-test_x.py` (3 tests)' '- `tests/test_p.py` (3 tests)'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: NOT CHECKED pytest-count: `../x/test_o.py` (3 tests) — path refused (contains ..)'
    _has 'mr.md:2: NOT CHECKED pytest-count: `tests/test_u.py` (3 tests) — not tracked at HEAD'
    _has 'mr.md:3: NOT CHECKED pytest-count: `-test_x.py` (3 tests) — path refused (leading -)'
    _has 'mr.md:4: MISMATCH pytest-count:'
    run grep -qE 'test_o|test_u|test_x' "$PYLOG"; [ "$status" -eq 1 ]
    [ "$(_collections)" -eq 1 ]
}

@test "SUITE_CHILD_UNSET is the one list" {
    local r="$DEVAGENT_ROOT/scripts"
    [ "$(grep -c '^SUITE_CHILD_UNSET=' "$r/lib/config.sh")" -eq 1 ]
    run grep -c '_child_unset' "$r/run-suite.sh"; [ "$output" -eq 0 ]
    [ "$(grep -cF '"${SUITE_CHILD_UNSET[@]}"' "$r/run-suite.sh")" -eq 2 ]
    [ "$(grep -cF '"${SUITE_CHILD_UNSET[@]}"' "$r/claims-check.sh")" -eq 1 ]
    # Behaviour: the collection child never sees the session pin.
    _py_fixture
    _body '- `tests/test_p.py` (3 tests)'
    DEVAGENT_ACTIVE_ISSUE=Issue-1 _cc "$TEST_PROJECT"
    [ "$status" -eq 3 ]
    grep -qF -- '--collect-only -q ./tests/test_p.py|PDWB=1|PIN=unset' "$PYLOG"
}

# ---- Task 7: suite totals (U1-U3) ------------------------------------------------------
ART() { printf '%s\n' "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"; }
# _evsuite <ok/plan | (none)> <pytest passed | (none)> [<head>] - SUITE: the canonical
# suite: value, built by the REAL evidence_suite_resolve from an artifact (Issue-232).
_evsuite() {
    local b p
    if [ "$1" = '(none)' ]; then b='(none)'; else b="$1 notok=0"; fi
    if [ "$2" = '(none)' ]; then p='(none)'; else p="$2 passed, 0 failed"; fi
    printf 'head: %s  dirty: no\nbats: %s\npytest: %s\n' "${3:-$(_head)}" "$b" "$p" > "$(ART)"
    SUITE="$(bash -c '. "$1/scripts/lib/paths.sh"; . "$1/scripts/lib/io.sh"; . "$1/scripts/lib/config.sh"
        . "$1/scripts/lib/platform.sh"; . "$1/scripts/lib/evidence.sh"
        evidence_suite_resolve "$2"; printf %s "$EVIDENCE_SUITE_LINE"' _ "$DEVAGENT_ROOT" "$(ART)")"
    [ -n "$SUITE" ]
}
# _bodyev <line>... - mr.md: the lines, then an Evidence block carrying suite: $SUITE.
_bodyev() { _body "$@" '## Evidence' "suite: $SUITE" 'files: 1 changed'; }

@test "a differing prose total is reported, an equal one is not; compared with mr.md's Evidence line, not the artifact" {
    _evsuite 100/100 20
    [ "$SUITE" = "100/100 bats, 20 pytest @ $(_head)" ]
    printf 'head: %s  dirty: no\nbats: 7/7 notok=0\npytest: 9 passed, 0 failed\n' "$(_head)" > "$(ART)"   # the artifact differs
    _bodyev '- 99/100 bats' '- 21 pytest passed' '- The full bats suite: 99 passed' \
            '- 100/100 bats' '- 20 pytest passed' '- The full pytest suite: 20 passed'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH suite-total: 99/100 bats — claimed 99/100, found 100/100 (Evidence suite:)'
    _has 'mr.md:2: MISMATCH suite-total: 21 pytest — claimed 21, found 20 (Evidence suite:)'
    _has 'mr.md:3: MISMATCH suite-total: 99 passed — claimed 99, found 100 (Evidence suite:)'
    _hasnt 'mr.md:4:'; _hasnt 'mr.md:5:'; _hasnt 'mr.md:6:'
    [ "$(_summary)" = "$(_sum 0 0 6 0 0 0 0 3 0)" ]
}

@test "an unlabelled total equal to the plan, n or plan+n is not reported" {
    _evsuite 100/100 20
    _bodyev '- The full suite: 100 passed' '- The whole suite: 20 passed' '- The entire suite: 120 tests passed' \
            '- The full suite: 121 passed' '- Full suite: 120/120'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:4: MISMATCH suite-total: 121 passed — claimed 121, found 100 (bats), 20 (pytest) or 120 (both) (Evidence suite:)'
    [ "$(grep -c MISMATCH <<<"$output")" -eq 1 ]
    [ "$(_summary)" = "$(_sum 0 0 5 0 0 0 0 1 0)" ]
}

@test "a total naming a commit is NOT CHECKED" {
    _evsuite 100/100 20
    _bodyev '- 99/100 bats at abc1234' '- At abc1234, 99/100 bats' '- 99/100 bats @ abc1234' \
            "- 99/100 bats at $(_head)" '- The full suite: 720 passed at HEAD' '- 21 pytest at HEAD'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED suite-total: 99/100 bats — measured at abc1234'
    _has 'mr.md:2: NOT CHECKED suite-total: 99/100 bats — measured at abc1234'
    _has 'mr.md:3: NOT CHECKED suite-total: 99/100 bats — measured at abc1234'
    _has "mr.md:4: NOT CHECKED suite-total: 99/100 bats — measured at $(_head)"
    _has 'mr.md:5: NOT CHECKED suite-total: 720 passed — measured at HEAD'
    _has 'mr.md:6: NOT CHECKED suite-total: 21 pytest — measured at HEAD'
    [ "$(grep -c 'NOT CHECKED suite-total' <<<"$output")" -eq 6 ]
    [ "$(grep -c 'NOT CHECKED cited-commit: abc1234' <<<"$output")" -eq 3 ]   # Task 9: the tokens are cited
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 1 0 0 9)" ]
}

@test "T1: '#466 pytest' and 'bats 1321/1321, pytest 298' read no total" {
    _evsuite 100/100 20
    _bodyev '- see #466 pytest.' '- bats 1321/1321, pytest 298'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _bodyev '- see 466 pytest.'                                             # the survivor
    _ccr
    [ "$status" -eq 3 ]; _has 'mr.md:1: MISMATCH suite-total: 466 pytest — claimed 466, found 20 (Evidence suite:)'
}

@test "T2/T8 refusals beside survivors" {
    _evsuite 100/100 20
    _bodyev '- 1 pytest test' '- X=1 pytest' '- 4 pytest-style' '- 3 pytest guards' '- 2 pytest failures' '- 12 pytests' \
            '- 374 pytest passed' '- 12 pytest green' '- (298 pytest)' '- 9 pytest in the clone'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:7: MISMATCH suite-total: 374 pytest'; _has 'mr.md:8: MISMATCH suite-total: 12 pytest'
    _has 'mr.md:9: MISMATCH suite-total: 298 pytest'; _has 'mr.md:10: MISMATCH suite-total: 9 pytest'
    [ "$(_summary)" = "$(_sum 0 0 4 0 0 0 0 4 0)" ]
}

@test "a pytest total in a code span is a quote" {
    _evsuite 100/100 20
    _bodyev '- `…, 0 pytest`' '- ``a ` b, 0 pytest``'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _bodyev '- …, 0 pytest' '- `x`, 0 pytest'                              # the same text, unquoted
    _ccr
    [ "$status" -eq 3 ]; [ "$(_summary)" = "$(_sum 0 0 2 0 0 0 0 2 0)" ]
}

@test "After code review (<sha>), N pytest passed → NOT CHECKED \"measured at\"" {
    _evsuite 100/100 20
    _bodyev '- After code review (abc1234), 21 pytest passed' '- Code review done, 21 pytest passed'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: NOT CHECKED suite-total: 21 pytest — measured at abc1234'
    _has 'mr.md:2: MISMATCH suite-total: 21 pytest — claimed 21, found 20 (Evidence suite:)'
}

@test "the S2 fixes stay S2-only" {
    _evsuite 100/100 20
    _bodyev '- `99/100 bats`' '- After review (abc1234), 99/100 bats'
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:1: MISMATCH suite-total: 99/100 bats'; _has 'mr.md:2: MISMATCH suite-total: 99/100 bats'
    [ "$(_summary)" = "$(_sum 0 0 2 0 0 0 0 2 1)" ]                         # (abc1234) is cited (Task 9)
}

@test "delta D1: S3 against 'suite: none @ <head>' → NOT CHECKED; S1 against a pytest-only line and S2 against a bats-only line → NOT CHECKED" {
    _evsuite '(none)' '(none)'
    [ "$SUITE" = "none @ $(_head)" ]
    _bodyev '- The full suite: 120 passed'
    _ccr
    [ "$status" -eq 0 ]; _has 'mr.md:1: NOT CHECKED suite-total: 120 passed — Evidence suite: line has no figures'
    _evsuite '(none)' 20
    _bodyev '- 99/100 bats'
    _ccr
    [ "$status" -eq 0 ]; _has 'mr.md:1: NOT CHECKED suite-total: 99/100 bats — Evidence suite: line has no bats figures'
    _evsuite 100/100 '(none)'
    _bodyev '- 21 pytest passed'
    _ccr
    [ "$status" -eq 0 ]; _has 'mr.md:1: NOT CHECKED suite-total: 21 pytest — Evidence suite: line has no pytest figures'
}

@test "an Evidence suite: line not at HEAD, or absent → NOT CHECKED; 3,994 equals 3994" {
    _evsuite 100/100 20 "$BASELINE"
    _bodyev '- 99/100 bats'
    _ccr
    [ "$status" -eq 0 ]; _has 'mr.md:1: NOT CHECKED suite-total: 99/100 bats — Evidence suite: line is not at HEAD'
    _body '- 99/100 bats'
    _ccr
    [ "$status" -eq 0 ]; _has 'mr.md:1: NOT CHECKED suite-total: 99/100 bats — no Evidence suite: line'
    _evsuite 3994/3994 '(none)'
    _bodyev '- 3,994/3,994 bats' '- The full bats suite: 3,994 passed'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 2 0 0 0 0 0 0)" ]
}

# ---- Task 8: commit and file counts -------------------------------------------------
# setup: baseline..HEAD is one signed commit changing one file (f2.txt).

@test "9 signed-off commits vs 2 → MISMATCH (… <base12>..HEAD), and the equal case" {
    echo three > "$SOURCE_DIR/f3.txt"; _commit three
    _body '- This branch has 9 signed-off commits.'
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH commit-count: 9 signed-off commits — claimed 9, found 2 (${BASELINE:0:12}..HEAD)"
    [ "$(_summary)" = "$(_sum 0 0 0 1 0 0 0 1 0)" ]
    _body '- This branch has 2 signed-off commits.' '- Signed-off-by on all 2 commits'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 2 0 0 0 0 0)" ]
}

@test "(3 files, +10/-2) and 3 files changed vs 1 → MISMATCH, and the equal case" {
    _body '- Diff (3 files, +10/-2).' '- 3 files changed' '- 3 changed files'
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH files-count: (3 files — claimed 3, found 1 (${BASELINE:0:12}..HEAD)"
    _has "mr.md:2: MISMATCH files-count: 3 files changed — claimed 3, found 1 (${BASELINE:0:12}..HEAD)"
    _has "mr.md:3: MISMATCH files-count: 3 changed files — claimed 3, found 1 (${BASELINE:0:12}..HEAD)"
    [ "$(_summary)" = "$(_sum 0 0 0 0 3 0 0 3 0)" ]
    _body '- Diff (1 file, +1/-0).' '- 1 file changed'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 2 0 0 0 0)" ]
}

@test "checkout 35 commits in an unrelated sentence → commit-count 0" {
    _body '- Upstream gained 35 commits since the checkout.'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body '- The branch is 35 commits ahead of master.'                    # the survivor: a branch sentence
    _ccr
    [ "$status" -eq 3 ]; _has "mr.md:1: MISMATCH commit-count: 35 commits — claimed 35, found 1 (${BASELINE:0:12}..HEAD)"
}

@test "T1: 'step-12 commit' and '#7 commits' in a signed-off sentence → commit-count 0" {
    _body '- Signed-off: the step-12 commit and #7 commits.'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body '- Signed-off: the 7 commits.'                                      # the survivor
    _ccr
    [ "$status" -eq 3 ]; _has "mr.md:1: MISMATCH commit-count: 7 commits — claimed 7, found 1 (${BASELINE:0:12}..HEAD)"
}

@test "a C1 number inside a C2 match is skipped (A12)" {
    _body '- Signed-off: 1 of 2 commits.'
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH commit-count: 1 of 2 commits — claimed 2, found 1 (${BASELINE:0:12}..HEAD)"
    [ "$(_summary)" = "$(_sum 0 0 0 1 0 0 0 1 0)" ]
}

@test "a commit or file count with an at-commit or earlier qualifier → NOT CHECKED" {
    _body '- On this branch: 9 commits at abc1234.' '- On this branch there were 9 commits.' \
          '- 3 files changed at HEAD' '- previously 3 files changed' '- partial diff: 3 files changed'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED commit-count: 9 commits — measured at abc1234'
    _has "mr.md:2: NOT CHECKED commit-count: 9 commits — an earlier run ('were')"
    _has 'mr.md:3: NOT CHECKED files-count: 3 files changed — measured at HEAD'
    _has "mr.md:4: NOT CHECKED files-count: 3 files changed — an earlier run ('previously')"
    _has "mr.md:5: NOT CHECKED files-count: 3 files changed — a partial run ('partial')"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 6)" ]                         # abc1234 is cited (Task 9)
}

# ---- Task 9: cited commits, amended (U4) ---------------------------------------------
# default_baseline is origin/main (helpers/common); the ref is a LOCAL refs/remotes/origin/main
# set by update-ref, so nothing touches a network.
# _side - a commit on a side branch that HEAD does not contain; SIDE is its sha.
_side() {
    git -C "$SOURCE_DIR" checkout -q -b "${1:-side}"
    echo side > "$SOURCE_DIR/side.txt"; _commit side
    SIDE="$(_head)"
    git -C "$SOURCE_DIR" checkout -q main
}
# _pair - two commit objects whose ids share the prefix 25e9e3a (imPlan Pre-plan inputs).
_pair() {
    local n
    for n in 20700 42160; do
        printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nm%s\n' "$n" \
            | git -C "$SOURCE_DIR" hash-object -t commit -w --stdin >/dev/null
    done
}

@test "an unknown token is NOT CHECKED \"resolves to no single local commit\"" {
    _body '- Fixed in `abcdef1`.'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED cited-commit: abcdef1 — abcdef1 resolves to no single local commit'
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 1)" ]
    _body "- Fixed in \`${BASELINE:0:7}\`."                                    # the survivor: a commit on HEAD
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 0 1 0 0 0)" ]
}

@test "an ambiguous prefix (25e9e3a) is NOT CHECKED; a blob id and a tree id are NOT CHECKED" {
    _pair
    local blob tree; blob="$(echo x | git -C "$SOURCE_DIR" hash-object -w --stdin)"; tree="$(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}')"
    _body '- See `25e9e3a`.' "- Blob \`$blob\`." "- Tree \`$tree\`."
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED cited-commit: 25e9e3a — 25e9e3a resolves to no single local commit'
    _has "mr.md:2: NOT CHECKED cited-commit: $blob — $blob resolves to no single local commit"
    _has "mr.md:3: NOT CHECKED cited-commit: $tree — $tree resolves to no single local commit"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 3)" ]
}

@test "a local side-branch commit reachable from neither → MISMATCH naming the ref; from the ref or HEAD → not reported" {
    _side
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$HEAD_SHA"
    _body "- Cherry-picked from ${SIDE:0:9}."
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH cited-commit: ${SIDE:0:9} — claimed a commit on the branch or origin/main, found local commit reachable from neither HEAD nor origin/main (origin/main)"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 1 0 1 0)" ]
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$SIDE"         # now reachable from the ref only
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 0 1 0 0 0)" ]
    _body "- Built on ${HEAD_SHA:0:9}."                                        # reachable from HEAD
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 0 1 0 0 0)" ]
}

@test "a SHA inside a URL is not recognised; ref unresolvable and commit not in HEAD → NOT CHECKED" {
    _side
    _body "- See https://github.com/o/r/commit/$SIDE for it."
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
    _body "- Cherry-picked from \`${SIDE:0:9}\`."                               # no refs/remotes/origin/main here
    _ccr
    [ "$status" -eq 0 ]
    _has "mr.md:1: NOT CHECKED cited-commit: ${SIDE:0:9} — not reachable from HEAD, and origin/main does not resolve here"
}

@test "at \`--all\` → NOT CHECKED, absent from the git argv log; .devagent-baseline names the ref" {
    _tests tests/f.bats 5; _commit f
    _gitshim no-such-subcommand 3
    _body '- `tests/f.bats` (4 tests) at `--all`'
    _ccr
    [ "$status" -eq 0 ]
    _has 'mr.md:1: NOT CHECKED bats-count: `tests/f.bats` (4 tests) — measured at --all'
    run grep -q -- '--all' "$GITLOG"; [ "$status" -eq 1 ]
    unset DEVAGENT_GIT
    _side dev/x
    echo dev/x > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    _body "- From ${SIDE:0:9}."
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 0 1 0 0 0)" ]           # reachable from dev/x
    git -C "$SOURCE_DIR" branch -q -f dev/x main
    _ccr
    [ "$status" -eq 3 ]; _has "found local commit reachable from neither HEAD nor dev/x (dev/x)"
}

@test "H2 under bash =~ (A1)" {
    _body '- see 1a2b3c4 here' '- see 1a2b3c4, x' '- (1a2b3c4)' '- [1a2b3c4]'
    _ccr
    [ "$status" -eq 0 ]
    local i; for i in 1 2 3 4; do _has "mr.md:$i: NOT CHECKED cited-commit: 1a2b3c4"; done
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 4)" ]
    _body '- see 1a2b3c4x here' '- see abcdefa here' '- see 1234567 here' '- see x1a2b3c4 here'   # not H2
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$ZERO_SUM" ]
}

@test "every git call carrying an mr.md token runs with GIT_NO_LAZY_FETCH=1" {
    _tests tests/f.bats 5; _commit f; _side
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$HEAD_SHA"
    _gitshim no-such-subcommand 3
    _body "- From \`${SIDE:0:9}\` and ${BASELINE:0:9}." "- \`tests/f.bats\` (4 tests) at ${BASELINE:0:9}"
    _ccr
    [ "$status" -eq 3 ]
    local tok n=0 l
    for tok in "${SIDE:0:9}" "${BASELINE:0:9}" 'tests/f.bats'; do
        while IFS= read -r l; do
            n=$((n + 1))
            [[ "$l" == NLF=1\ * ]] || { echo "lazy fetch possible: $l"; return 1; }
        done < <(grep -F -- "$tok" "$GITLOG")
    done
    [ "$n" -ge 5 ]                                                         # rev-parse x2, merge-base, cat-file -e/-p
}

# ---- Task 10: the sign-off box and the read-only invariant -------------------------------

@test "a ticked box with one unsigned commit → MISMATCH naming its sha12; all signed → not reported" {
    _body '- [x] Every commit is signed off (DCO)'
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 0 0 0 0 0 0 1 0 0)" ]           # setup's commits are signed
    echo u > "$SOURCE_DIR/u.txt"; git -C "$SOURCE_DIR" add -A; git -C "$SOURCE_DIR" commit -q -m unsigned
    local u; u="$(_head)"
    git -C "$SOURCE_DIR" checkout -q -b topic HEAD~1; echo t > "$SOURCE_DIR/t.txt"; _commit topic
    git -C "$SOURCE_DIR" checkout -q main; git -C "$SOURCE_DIR" merge -q --no-ff -m 'merge topic' topic
    local mg; mg="$(_head)"                                                  # an unsigned merge
    _ccr
    [ "$status" -eq 3 ]
    _has "mr.md:1: MISMATCH signoff: [x] Every commit is signed off (DCO) — claimed every commit signed off, found unsigned ${mg:0:12}, ${u:0:12} (${BASELINE:0:12}..HEAD)"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 1 1 0)" ]
}

@test "an unticked box is not a claim" {
    echo u > "$SOURCE_DIR/u.txt"; git -C "$SOURCE_DIR" add -A; git -C "$SOURCE_DIR" commit -q -m unsigned
    _body '- [ ] Every commit is signed off' '- [x] Not signed off yet: not all commits' '- [x] DCO: 2 commits unsigned' \
          '* [X] Signed-off-by on every commit'
    _ccr
    [ "$status" -eq 3 ]
    _hasnt 'mr.md:1:'; _hasnt 'mr.md:2:'; _hasnt 'mr.md:3: MISMATCH signoff'
    _has 'mr.md:4: MISMATCH signoff: [X] Signed-off-by on every commit'          # the survivor: * and [X]
}

# _all_kinds - a body with one claim of each of the seven kinds, every one compared.
_all_kinds() {
    _tests tests/f.bats 5; _commit f; _side
    git -C "$SOURCE_DIR" update-ref refs/remotes/origin/main "$HEAD_SHA"
    _evsuite 5/5 4
    _bodyev '- `tests/f.bats` (4 tests)' '- `tests/test_p.py` (3 tests)' '- 99/100 bats' \
            '- On this branch: 9 commits.' '- 7 files changed' "- From \`${SIDE:0:9}\`." '- [x] All signed off (DCO)'
}
# _state - what a read-only run must leave unchanged.
_state() {
    sha256sum "$(MR)"; git -C "$SOURCE_DIR" rev-parse HEAD
    git -C "$SOURCE_DIR" status --porcelain --ignored -uall
}

@test "after a run over a body with all seven kinds, mr.md's sha256, HEAD and status --porcelain --ignored -uall are unchanged (the .venv stub)" {
    _py_fixture; _all_kinds; _pyart "$VENV_PY"
    local before; before="$(_state)"
    _ccr
    [ "$status" -eq 3 ]
    [ "$(_summary)" = "$(_sum 1 1 1 1 1 1 1 6 0)" ]                            # every kind compared
    [ "$(_state)" = "$before" ]
}

@test "after a run over a body with all seven kinds, the tree is unchanged (real pytest, skip if absent)" {
    _real_pytest; _all_kinds; _pyart "$DEVAGENT_PYTEST_PYTHON"
    printf 'import pytest\n\n@pytest.mark.parametrize("x", [1, 2, 3])\ndef test_a(x):\n    assert x\n' > "$SOURCE_DIR/tests/test_p.py"
    _commit p; _evsuite 5/5 4; _pyart "$DEVAGENT_PYTEST_PYTHON"
    _bodyev '- `tests/f.bats` (4 tests)' '- `tests/test_p.py` (2 tests)' '- 99/100 bats' \
            '- On this branch: 9 commits.' '- 7 files changed' "- From \`${SIDE:0:9}\`." '- [x] All signed off (DCO)'
    local before; before="$(_state)"
    _ccr
    [ "$status" -eq 3 ]
    _has 'mr.md:2: MISMATCH pytest-count: `tests/test_p.py` (2 tests) — claimed 2, found 3 (at HEAD)'
    [ "$(_summary)" = "$(_sum 1 1 1 1 1 1 1 6 0)" ]
    [ "$(_state)" = "$before" ]
    [ -z "$(find "$SOURCE_DIR" -name __pycache__ -o -name .pytest_cache)" ]
}

# ---- Task 11: the preship.md claims line, run as written (Issue-461) -----------------------
@test "the preship.md claims line runs as written (#1122)" {
    local body
    body="$(awk 'index($0, "# recipe: claims") == 1 {f=1} f && /^```$/ {exit} f' "$DEVAGENT_ROOT/commands/preship.md")"
    [ -n "$body" ]
    body="${body//<project>/$TEST_PROJECT}"; body="${body//<Issue-N>/Issue-1}"
    _tests tests/x.bats 27; _commit x
    _body '- `tests/x.bats` (26 tests)'
    TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_PLUGIN_ROOT="$DEVAGENT_ROOT" run bash -c "$body"
    [ "$status" -eq 0 ]
    _has 'mr.md:1: MISMATCH bats-count: `tests/x.bats` (26 tests) — claimed 26, found 27 (at HEAD)'
    _has 'claims rc=3'
    [ -s "$BATS_TEST_TMPDIR/devagent-claims-Issue-1.out" ]
}

# ---- Task 12: the writer and the checker count alike --------------------------------------
@test "the writer's count command and claims-check count the same on a fixture" {
    local cmd n
    cmd="$(grep -oF "grep -cE '^[[:blank:]]*@test[[:blank:]]' <file>" "$DEVAGENT_ROOT/skills/core-draft-mr/SKILL.md" | head -1)"
    [ -n "$cmd" ]
    mkdir -p "$SOURCE_DIR/tests"
    printf '%s\n' '#!/usr/bin/env bats' '@test "a" {' '}' '  @test "indented" {' '}' '	@test "tab" {' '}' \
        '# @test "a comment"' '@testing x' 'x @test "mid-line"' '@test	"tab after"' > "$SOURCE_DIR/tests/w.bats"
    _commit w
    n="$(cd "$SOURCE_DIR" && bash -c "${cmd//<file>/tests/w.bats}")"
    [ "$n" -eq 4 ]                                                       # the planted shapes: 4 real
    _body "- \`tests/w.bats\` ($n tests)"
    _ccr
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 1 0 0 0 0 0 0 0 0)" ]
    _body "- \`tests/w.bats\` ($((n + 1)) tests)"
    _ccr
    [ "$status" -eq 3 ]; _has "claimed $((n + 1)), found $n (at HEAD)"
}
