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
    [ "$status" -eq 0 ]; [ "$output" = "$(_sum 1 0 0 0 0 0 0 0 0)" ]
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
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 2)" ]
}

@test "a file absent at the at-commit → NOT CHECKED \"absent at <sha12>\"" {
    _tests tests/f.bats 5; _commit f
    _body "- \`tests/f.bats\` (4 tests) at ${BASELINE:0:9}"
    _ccr
    [ "$status" -eq 0 ] || { echo "rc=$status"; echo "$output"; return 1; }
    _has "mr.md:1: NOT CHECKED bats-count: \`tests/f.bats\` (4 tests) — absent at ${BASELINE:0:12}"
    [ "$(_summary)" = "$(_sum 0 0 0 0 0 0 0 0 1)" ]
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
    ! grep -qE 'outside|u\.bats|-rf' "$GITLOG"
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
    _hasnt 'mr.md:4:'
    _has 'mr.md:9: MISMATCH bats-count:'                       # the same line after the block
    [ "$(_summary)" = "$(_sum 1 0 0 0 0 0 0 1 0)" ]
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
