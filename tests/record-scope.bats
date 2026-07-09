#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    BASE="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASE"
    # opt-in: commit_autostage=true in the project section
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.commit_autostage" true
    REC="$DEVAGENT_ROOT/scripts/record-scope.sh"
    SCOPE="$DEVDOC_DIR/Issue-1/.devagent-scope"
}
teardown() { devagent_test_teardown; }

@test "records edited tracked + untracked paths, sorted, with marker (#268 AC1)" {
    ( cd "$SOURCE_DIR" && echo x >> README.md && echo new > z_new.txt )
    run "$REC" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -f "$SCOPE" ]
    [ -f "$SCOPE.auto" ]                 # auto-generated sentinel (not an in-file marker)
    run grep -q '^#' "$SCOPE"            # manifest is pure paths (no comment line)
    [ "$status" -ne 0 ]
    grep -qx 'README.md' "$SCOPE"
    grep -qx 'z_new.txt' "$SCOPE"
}

@test "end-to-end: produced manifest drives #251 commit.sh autostage (#268 AC1+AC2)" {
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x && echo x >> README.md && echo new > z_new.txt )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    echo feature > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo scope-test > "$DEVDOC_DIR/Issue-1/.devagent-title"
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' '' 'Issue: {{issue}}' > "$DEVDOC_DIR/templates/commit_template.md"
    "$REC" "$TEST_PROJECT"                                   # produce manifest
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1   # #251 consumes it
    [ "$status" -eq 0 ]
    # both edited files are in the resulting commit (manifest was accepted + staged)
    committed="$( cd "$SOURCE_DIR" && git show --name-only --pretty=format: HEAD )"
    echo "$committed" | grep -qx 'README.md'
    echo "$committed" | grep -qx 'z_new.txt'
}

@test "a glob-metachar edited path fails loud, no partial manifest (#268 AC3)" {
    ( cd "$SOURCE_DIR" && touch 'f[1].txt' )   # untracked, reject-vector filename
    run "$REC" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"glob metacharacter"* ]]
    [ ! -f "$SCOPE" ]   # no partial manifest written
}

@test "edited-then-reverted file is not a stale entry (#268 AC4)" {
    ( cd "$SOURCE_DIR" && echo x >> README.md )
    "$REC" "$TEST_PROJECT"; grep -qx 'README.md' "$SCOPE"
    ( cd "$SOURCE_DIR" && git checkout -- README.md )   # revert
    "$REC" "$TEST_PROJECT"
    run grep -qx 'README.md' "$SCOPE"
    [ "$status" -ne 0 ]   # dropped on regenerate
}

@test "re-run after a second edit converges (no dup/strand) (#268 AC5)" {
    ( cd "$SOURCE_DIR" && echo x >> README.md ); "$REC" "$TEST_PROJECT"
    ( cd "$SOURCE_DIR" && echo y > z_two.txt ); "$REC" "$TEST_PROJECT"
    [ "$( grep -cx 'README.md' "$SCOPE" )" -eq 1 ]   # not duplicated
    grep -qx 'z_two.txt' "$SCOPE"                     # second edit present
}

@test "recording off (commit_autostage unset) writes no manifest (#268 AC6)" {
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.commit_autostage"
    ( cd "$SOURCE_DIR" && echo x >> README.md )
    run "$REC" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ ! -f "$SCOPE" ]
}

@test "implement.md wires record-scope gated on commit_autostage (#268 AC8 doc)" {
    grep -q 'record-scope.sh' "$DEVAGENT_ROOT/commands/implement.md"
    grep -q 'commit_autostage' "$DEVAGENT_ROOT/commands/implement.md"
}

@test "operator-authored manifest is not clobbered (#268 AC7)" {
    printf '%s\n' 'README.md' > "$SCOPE"   # hand-authored, no marker
    ( cd "$SOURCE_DIR" && echo x >> README.md && echo new > z_new.txt )
    run "$REC" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"operator-authored"* ]]
    [ "$( cat "$SCOPE" )" = "README.md" ]   # untouched
}
