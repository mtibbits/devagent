#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    ( cd "$DEVDOC_DIR" \
      && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com \
      && git config user.name Test \
      && git add . \
      && git commit -q -m "seed" )
    # Local main branch in source repo for the checkout.
    ( cd "$SOURCE_DIR" && git branch -f main )
}
teardown() { devagent_test_teardown; }

@test "cleanup.sh switches source tree to main, commits devdoc, clears active_issue" {
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "main" ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -ge 2 ]
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -qE '^- \[x\] +20\. cleanup' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "cleanup.sh skips devdoc commit when commit_devdoc=false" {
    sed -i "s|^commit_devdoc *=.*|commit_devdoc = false|" "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}

@test "cleanup.sh commits an entirely-untracked (fresh) issue dir (#140)" {
    # A fresh Issue-2 dir created this cycle is fully untracked; with
    # commit_devdoc=true the auto-commit must still see it (the old tracked-only
    # diff guard was blind to untracked files).
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    sed -i "s|^active_issue *=.*|active_issue   = \"Issue-2\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^issue_dir *=.*|issue_dir      = \"$DEVDOC_DIR/Issue-2\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    before=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -eq 0 ]
    after=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$after" -eq $((before + 1)) ]
    # the previously-untracked dir is now tracked and the tree is clean
    ( cd "$DEVDOC_DIR" && git ls-files --error-unmatch Issue-2/checklist.md )
    [ -z "$( cd "$DEVDOC_DIR" && git status --porcelain )" ]
}

@test "cleanup.sh reconciles the WBS leaf for the completed issue to [x]" {
    # Mark every step except step 20 done in the seeded checklist;
    # cleanup will mark step 20 itself, then call wbs update.
    sed -i 's/^- \[ \]\([ ]*\([0-9]*\)\.\)/- [x]\1/' \
        "$DEVDOC_DIR/Issue-1/checklist.md"
    # Re-mark step 20 as pending so cleanup has work to do.
    sed -i 's/^- \[x\]\([ ]*20\.\)/- [ ]\1/' \
        "$DEVDOC_DIR/Issue-1/checklist.md"
    # Seed a WBS with the issue's leaf in-progress.
    cat > "$DEVDOC_DIR/WBS.md" <<EOF
# $TEST_PROJECT WBS

- [ ] Plan {est: 1w}
  - [~] Working leaf {issue: Issue-1, est: 1w}
EOF
    ( cd "$DEVDOC_DIR" && git add -A && \
        git -c user.email=t@x -c user.name=t commit -q -m "seed wbs" )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # cleanup marks its own step 20, then calls wbs update, which sees
    # all checklist lines [x] and flips the leaf to [x].
    grep -q "\[x\] Working leaf" "$DEVDOC_DIR/WBS.md"
}

@test "cleanup.sh soft-passes when no WBS.md exists (--if-exists)" {
    # No WBS.md in this fixture by default — cleanup should not fail
    # nor warn.
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"wbs reconcile failed"* ]]
}

@test "cleanup.sh clears per-issue keys (mr_url/baseline_sha/revision) (#98)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" mr_url "https://example.com/pr/9"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" baseline_sha "abc123"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set-int "$f" revision 3
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^mr_url = ""$' "$f"
    grep -qE '^baseline_sha = ""$' "$f"
    grep -qE '^revision = 1$' "$f"
    # Quoted "20" is deliberate: cleanup re-sets last_step via the string-typed
    # state_set AFTER the clear, preserving today's stored form exactly.
    grep -qE '^last_step = "20"$' "$f"
}

@test "cleanup.sh garbage-collects the issue's [context] snapshot (#98 review m4)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" context.Issue-1.branch "feat/1-x"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-1.branch
    [ "$status" -ne 0 ]
}

@test "cleanup.sh GCs the snapshot when \$2 is the issue-dir PATH (#98 redmr MIN-3)" {
    f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" set "$f" context.Issue-1.branch "feat/1-x"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-1"
    [ "$status" -eq 0 ]
    run python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get "$f" context.Issue-1.branch
    [ "$status" -ne 0 ]
}
