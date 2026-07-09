#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Pre-stage a change in the working tree.
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
      && echo hello > a.txt && git add a.txt )
    # Active issue marker for commit body.
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "add a.txt" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    # Pre-populate state.branch via direct edit (simulates branch.sh having run).
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
teardown() { devagent_test_teardown; }

@test "commit.sh writes commit using commit_template body with -s" {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' '' 'Issue: {{issue}}' \
        > "$DEVDOC_DIR/templates/commit_template.md"

    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    echo "$msg" | grep -qx "feat: add a.txt"
    echo "$msg" | grep -q "Issue: Issue-1"
    echo "$msg" | grep -q "^Signed-off-by:"
    grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit.sh dies when the latest born-red artifact is FLAGGED (#362)" {
    printf 'verdict: FLAGGED (1 green-at-baseline)\n' \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-born-red.txt"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"born-red gate"* ]]
}

@test "commit.sh commits normally with a PASS born-red artifact (#362)" {
    printf 'verdict: PASS\n' > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-born-red.txt"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "commit.sh commits normally with a NO-NEW-TESTS born-red artifact (#362)" {
    printf 'verdict: NO-NEW-TESTS\n' > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-born-red.txt"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "commit.sh strips (1M context) substring from message" {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}} (1M context)' '' 'body (1M context) trailing' \
        > "$DEVDOC_DIR/templates/commit_template.md"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    run grep -q "1M context" <<<"$msg"
    [ "$status" -ne 0 ]
}

@test "commit.sh default template renders type-prefixed subject, not conventions doc" {
    # Uses the SHIPPED default template (no swap). Verifies the placeholder
    # render and that neither the conventions doc nor the authoring comment leak.
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    # Subject: type=feature → feat; title="add a.txt".
    [ "$( echo "$msg" | head -1 )" = "feat: add a.txt" ]
    # Conventions doc must NOT leak into the body.
    run grep -q "VOLK Commit Message Conventions" <<<"$msg"
    [ "$status" -ne 0 ]
    # HTML authoring comment must NOT leak.
    run grep -q "Placeholder semantics" <<<"$msg"
    [ "$status" -ne 0 ]
    run grep -q '<!--' <<<"$msg"
    [ "$status" -ne 0 ]
    # DCO trailer from git commit -s.
    echo "$msg" | grep -q "^Signed-off-by:"
}

# include_coauthor strip-guard (#31). Inject a Co-Authored-By line via a PER-TEST,
# isolated template that artifact_resolve picks up at priority 2
# (<devdoc>/templates/<key>.md). $DEVDOC_DIR lives under the per-test
# $DEVAGENT_TMP, so this NEVER touches the live $DEVAGENT_ROOT/templates/ —
# failure-safe, no .bak/restore dance (DEVAGENT_ROOT is the live repo, not a copy).
@test "commit.sh strips Co-Authored-By when include_coauthor=false, keeps Signed-off-by" {
    sed -i '/^\[project\.'"$TEST_PROJECT"'\]/a include_coauthor = false' \
        "$HOME/.claude/devagent/config.toml"
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' '' 'body line' \
        'Co-Authored-By: Claude <noreply@anthropic.com>' \
        > "$DEVDOC_DIR/templates/commit_template.md"

    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    # NB: `! cmd | grep` is vacuous under bats (the `!` exempts it from the
    # failure trap); use run + status so a leaked trailer actually fails.
    run grep -qi "co-authored-by" <<<"$msg"
    [ "$status" -ne 0 ]
    echo "$msg" | grep -qx "body line"
    echo "$msg" | grep -q "^Signed-off-by:"
}

@test "commit.sh keeps Co-Authored-By when include_coauthor is unset (default true)" {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' '' 'body line' \
        'Co-Authored-By: Claude <noreply@anthropic.com>' \
        > "$DEVDOC_DIR/templates/commit_template.md"

    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    echo "$msg" | grep -qi "co-authored-by"
}

@test "commit.sh refuses to commit when HEAD differs from state.branch (#69)" {
    # mergetoall/cleanup can leave source_dir on another branch; state.branch is still
    # the issue branch. Committing here would land the work on the wrong branch and
    # re-ship would push the unchanged issue branch — the revision silently lost.
    ( cd "$SOURCE_DIR" && git checkout -q -b dev/all-prs )   # HEAD now on the wrong branch; a.txt still staged
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to commit"* ]]
    [[ "$output" == *"feat/1-x"* ]]                          # names the expected issue branch
    grep -qE '^- \[ \] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"   # step 10 NOT marked done
    # The work-loss is actually prevented: nothing was committed anywhere — a.txt is
    # still staged-but-uncommitted, not landed on the wrong branch.
    ( cd "$SOURCE_DIR" && git diff --cached --name-only ) | grep -qx a.txt
    run bash -c "cd '$SOURCE_DIR' && git log --all --oneline | grep -c 'add a.txt'"
    [ "$output" -eq 0 ]
}

@test "commit.sh refuses to commit on a detached HEAD (#69)" {
    ( cd "$SOURCE_DIR" && git checkout -q --detach )         # detached; a.txt still staged
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to commit"* ]]
    [[ "$output" == *"detached HEAD"* ]]
    grep -qE '^- \[ \] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    ( cd "$SOURCE_DIR" && git diff --cached --name-only ) | grep -qx a.txt   # work preserved, not committed
}

# --- #116: per-task-commit flow --------------------------------------------

_set_baseline() {  # $1 = sha — REPLACE the existing (empty) key; sed-append
    # would create a duplicate top-level key and tomllib rejects the file (B1).
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"$1\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "commit.sh no-op success when work is already committed per-task (#116)" {
    base="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    ( cd "$SOURCE_DIR" && git commit -q -s -m "task 1: add a.txt" )
    _set_baseline "$base"
    head_before="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"already committed"* ]]
    # No new commit was created.
    [ "$( cd "$SOURCE_DIR" && git rev-parse HEAD )" = "$head_before" ]
    grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit.sh dies loud on dirty-unstaged tree even with commits ahead (#116/#25)" {
    base="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    ( cd "$SOURCE_DIR" && git commit -q -s -m "task 1" && echo more >> a.txt )
    _set_baseline "$base"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing is staged"* ]]
}

@test "commit.sh no-op ignores analyze-owned clutter via .gitignore (#324)" {
    # The #25 guard fires on analyze-owned clutter (build-asan/, err, .claude/)
    # left in the tree, forcing a manual mark (9 issues paid this). devagent's
    # own .gitignore must cover it, so the step-10 no-op path passes untouched.
    base="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    # devagent's REAL .gitignore, tracked so it doesn't itself dirty the tree.
    cp "${BATS_TEST_DIRNAME}/../.gitignore" "$SOURCE_DIR/.gitignore"
    ( cd "$SOURCE_DIR" && git add .gitignore && git commit -q -s -m "task 1: a.txt + gitignore" )
    _set_baseline "$base"
    # analyze-owned clutter appears untracked at commit time
    ( cd "$SOURCE_DIR" && mkdir -p build-asan build-tsan build-ubsan .claude \
      && touch build-asan/o err .claude/settings.local.json )
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"already committed"* ]]   # no-op success, NOT the #25 dirty die
}

@test "commit.sh refuses the no-op mark when HEAD is not the issue branch (#116/#69 interaction lock)" {
    base="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    ( cd "$SOURCE_DIR" && git commit -q -s -m "task 1" && git checkout -q -b other )
    _set_baseline "$base"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to commit"* ]]
    # Step 10 must NOT be marked done.
    run grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "commit.sh dies loud on indeterminate baseline instead of guessing (#116 review fix)" {
    # Clean tree, one commit ahead, but baseline_sha left empty ("" is the
    # fixture default) → classifier says indeterminate → must die, not mark
    # [-] artifact-only (which would misrecord real work) nor [x] no-op.
    ( cd "$SOURCE_DIR" && git commit -q -s -m "task 1" )
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot classify"* ]]
    run grep -qE '^- \[(x|-)\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
    [ "$status" -ne 0 ]
}

@test "commit refuses an empty branch when the branch step is done — resume-after-cleanup (#316)" {
    # The state resume-after-cleanup leaves behind: active_issue set, the issue's
    # recorded branch reset to "", but the branch step (6) still [x] — a branch
    # DID exist and was lost. A BARE commit (no arg, no pin) must refuse: the
    # #240 guard only covers pinned/arg sessions, so without #316 the bare flow
    # would commit staged work onto whatever HEAD is on and mark step 10 [x].
    sed -i 's|^branch *=.*|branch = ""|' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" "$DEVDOC_DIR/Issue-1" 6 x
    local before; before="$( cd "$SOURCE_DIR" && git rev-parse HEAD )"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT"      # BARE: no Issue-1 arg
    [ "$status" -ne 0 ]
    [[ "$output" == *"316"* ]]
    # Nothing committed (HEAD unchanged).
    [ "$( cd "$SOURCE_DIR" && git rev-parse HEAD )" = "$before" ]
    # Step 10 stays pending.
    grep -qE '^- \[ \] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit still tolerates an empty branch when the branch step is NOT done — legacy bare flow (#316)" {
    # branch step [ ] (never branched) + empty branch = the legitimate legacy
    # tolerance; the #316 guard must NOT fire (it gates on branch-step == x).
    sed -i 's|^branch *=.*|branch = ""|' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' > "$DEVDOC_DIR/templates/commit_template.md"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit does NOT refuse a healthy recorded branch with the branch step done, bare flow (#316 regression)" {
    # Guard silence on the healthy axis: a NON-EMPTY recorded branch + branch
    # step [x] on the bare path must commit normally (the #316 guard fires only
    # on an EMPTY branch). Mirrors the doctor healthy regression. setup already
    # recorded branch=feat/1-x and staged a.txt on feat/1-x.
    bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" "$DEVDOC_DIR/Issue-1" 6 x
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '{{type}}: {{title}}' > "$DEVDOC_DIR/templates/commit_template.md"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}
