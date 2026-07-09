#!/usr/bin/env bats
# #251 — opt-in scoped auto-staging in commit.sh. When commit_autostage=true and
# the issue declares an in-scope manifest (.devagent-scope), the
# dirty-but-nothing-staged guard stages exactly those paths and commits instead
# of dying. Default (off) and every can't-determine case must fall back to the
# #25 die-loud guard, and an out-of-scope file must never be staged.
load 'helpers/common'

setup() {
    devagent_test_setup
    # Branch at HEAD, zero commits ahead (artifact-only shape) so the guard's
    # dirty/staged branch is what decides — exactly the #25 path.
    local sha
    sha="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-autostage )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-autostage"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$sha"
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "autostage feature" > "$DEVDOC_DIR/Issue-1/.devagent-title"
}
teardown() { devagent_test_teardown; }

_enable_autostage() {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.commit_autostage" true
}

@test "autostage OFF (default): dirty-but-unstaged still dies loud (#25, AC1)" {
    ( cd "$SOURCE_DIR" && echo edit >> README.md )   # tracked, unstaged
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"git add"* ]]
    run grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "autostage ON + all dirty in scope: stages and commits, no manual add (AC2)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )
    printf 'README.md\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^\- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    # README.md is in the new commit.
    ( cd "$SOURCE_DIR" && git show --stat --name-only --format= HEAD ) | grep -qx "README.md"
    # Tree is clean afterwards (the only dirty path was staged + committed).
    [ -z "$( cd "$SOURCE_DIR" && git status --porcelain )" ]
}

@test "autostage ON + out-of-scope dirty file: in-scope staged, out-of-scope NEVER in commit (AC3)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo inscope >> README.md && echo outofscope > UNRELATED.txt )
    printf 'README.md\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # README.md committed; UNRELATED.txt provably absent from the commit.
    ( cd "$SOURCE_DIR" && git show --stat --name-only --format= HEAD ) | grep -qx "README.md"
    run bash -c "cd '$SOURCE_DIR' && git show --name-only --format= HEAD | grep -qx UNRELATED.txt"
    [ "$status" -ne 0 ]
    # UNRELATED.txt is still sitting untracked in the tree, never staged.
    ( cd "$SOURCE_DIR" && git status --porcelain UNRELATED.txt ) | grep -q '^?? UNRELATED.txt'
}

@test "autostage ON + NO .devagent-scope manifest: falls back to die-loud (AC4)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *".devagent-scope"* ]]
    run grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "autostage ON + DIRECTORY entry: die-loud, untracked sibling NEVER staged (over-capture guard, AC3)" {
    # A bare directory in the manifest would make `git add -- sub/` recurse and
    # capture untracked siblings the issue never touched. Must be rejected.
    _enable_autostage
    ( cd "$SOURCE_DIR" && mkdir -p sub && echo wanted > sub/wanted.txt \
        && echo unrelated > sub/UNRELATED.txt )
    printf 'sub\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]   # nothing staged
}

@test "autostage ON + pathspec-magic entry (:/): die-loud, whole-repo NOT staged (AC3)" {
    # ':/'/':(top)' are git pathspec magic that stage the entire repo — the banned
    # `git add -A` equivalent. Must be rejected (leading ':' guard).
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md && echo x > UNRELATED.txt )
    printf ':/\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
}

@test "autostage ON + absolute-path entry: die-loud, nothing staged" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )
    printf '%s\n' "$SOURCE_DIR/README.md" > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
}

@test "autostage ON + parent-traversal entry (../x): die-loud, nothing staged" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )
    printf '../escape.txt\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
}

@test "autostage ON + invalid manifest entry ('.') : die-loud, nothing staged (AC4, no over-capture)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md && echo x > UNRELATED.txt )
    printf '.\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"   # the banned "stage everything"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    # Nothing was staged (no over-capture of UNRELATED.txt).
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
    run grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "autostage ON + manifest entry with a leading dash: die-loud, nothing staged (flag-injection guard)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )
    printf -- '-A\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
}

@test "autostage ON + manifest paths not actually dirty: die-loud (nothing staged)" {
    _enable_autostage
    ( cd "$SOURCE_DIR" && echo edit >> README.md )       # dirty path NOT in manifest
    printf 'does-not-exist.txt\n' > "$DEVDOC_DIR/Issue-1/.devagent-scope"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ -z "$( cd "$SOURCE_DIR" && git diff --cached --name-only )" ]
    run grep -qE '^\- \[-\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}
