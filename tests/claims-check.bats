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
# _gitshim <subcommand> <rc> - DEVAGENT_GIT logs every call (argv and GIT_NO_LAZY_FETCH)
# to $GITLOG, exits <rc> when the first non-option word is <subcommand>, else runs git.
_gitshim() {
    GITLOG="$DEVAGENT_TMP/git.log"; : > "$GITLOG"
    local real; real="$(command -v git)"
    cat > "$DEVAGENT_TMP/gitshim" <<EOF
#!/usr/bin/env bash
printf 'NLF=%s %s\n' "\${GIT_NO_LAZY_FETCH-unset}" "\$*" >> '$GITLOG'
a=("\$@"); i=0
while [ "\$i" -lt "\${#a[@]}" ]; do case "\${a[\$i]}" in -C) i=\$((i + 2)) ;; -*) i=\$((i + 1)) ;; *) break ;; esac; done
[ "\${a[\$i]-}" = '$1' ] && exit $2
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
    [ "$status" -eq 0 ]
    [ "$output" = "$ZERO_SUM" ]
    [ -z "$stderr" ]
}
