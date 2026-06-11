#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b dev/all-prs \
      && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m "feat: x" )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
teardown() { devagent_test_teardown; }

# Point config + state at a test-built topology: all_prs_branch in config,
# branch + baseline_sha in state. Shared by the #33 tests below.
_set_baseline_branch() {
    sed -i "s|^all_prs_branch *=.*|all_prs_branch = \"$1\"|" "$HOME/.claude/devagent/config.toml"
    sed -i "s|^branch *=.*|branch = \"$2\"|; s|^baseline_sha *=.*|baseline_sha = \"$3\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "mergetoall.sh squash-merges branch into all_prs_branch" {
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "dev/all-prs" ]
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
    # Squash merges land as a single new commit, parent count == 1.
    parents=$( cd "$SOURCE_DIR" && git log -1 --pretty=%P dev/all-prs | wc -w )
    [ "$parents" -eq 1 ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh auto-skips when all_prs_branch is not configured" {
    sed -i "/^all_prs_branch *=/d" "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"all_prs_branch not configured"* ]]
    grep -qE '^- \[-\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q "auto-skipped: all_prs_branch not configured" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh halts when merge_to_all_prs=false and non-interactive" {
    sed -i "s|^merge_to_all_prs *=.*|merge_to_all_prs = false|" "$HOME/.claude/devagent/config.toml"
    # Force closed stdin so confirm() sees non-tty regardless of how bats
    # itself was invoked. Without </dev/null this hangs when bats is run
    # from an interactive terminal (read -r -p blocks waiting for input).
    run bash -c "'$DEVAGENT_ROOT/scripts/mergetoall.sh' '$TEST_PROJECT' Issue-1 </dev/null"
    [ "$status" -ne 0 ]
    grep -qE '^- \[ \] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh backward-compat: legacy merge_mr=true still grants permission" {
    # Remove the new name, add the old one.
    sed -i "/^merge_to_all_prs *=/d" "$HOME/.claude/devagent/config.toml"
    sed -i "/^push_mr *=/a merge_mr = true" "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh default does NOT push (local-only)" {
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_refute_logged "git push"
    grep -q "local-only" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh all_prs_auto_push=true pushes after local merge" {
    sed -i "/^all_prs_branch *=/a all_prs_auto_push = true" \
        "$HOME/.claude/devagent/config.toml"
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push origin dev/all-prs"
    grep -q "pushed to origin/dev/all-prs" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh all_prs_remote override targets a different remote" {
    sed -i "/^all_prs_branch *=/a all_prs_auto_push = true\nall_prs_remote = \"fork\"" \
        "$HOME/.claude/devagent/config.toml"
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push fork dev/all-prs"
}

@test "mergetoall.sh tolerates push failure (local merge is load-bearing)" {
    sed -i "/^all_prs_branch *=/a all_prs_auto_push = true" \
        "$HOME/.claude/devagent/config.toml"
    # Stub git that fails ONLY on push.
    mkdir -p "$DEVAGENT_TMP/bin"
    cat > "$DEVAGENT_TMP/bin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$DEVAGENT_STUB_LOG"
if [ "\$1" = "push" ]; then exit 1; fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "$DEVAGENT_TMP/bin/git"
    export DEVAGENT_GIT="$DEVAGENT_TMP/bin/git"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"push of dev/all-prs"*"failed"* ]]
    grep -q "push failed (local commit retained)" "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

# #33: a child branch stacked on a squash-merged parent must integrate ONLY its
# own delta (baseline_sha..HEAD), not re-derive the parent delta as conflicts.
@test "mergetoall.sh stacked child integrates only its own delta, no parent conflict (#33)" {
    cd "$SOURCE_DIR"
    git checkout -q main
    git checkout -q -b feat/parent
    printf 'L1\n' > shared.txt && git add shared.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m "parent: add shared.txt"
    parent_tip="$(git rev-parse HEAD)"
    git checkout -q -b feat/child
    echo child > child.txt && git add child.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m "child: add child.txt"
    # all_prs = base + squash(parent) + an INDEPENDENT edit to shared.txt by another PR,
    # so the OLD `git merge --squash feat/child` add/add-conflicts on shared.txt.
    git checkout -q -b allprs main
    git merge --squash feat/parent >/dev/null
    git -c user.email=t@e.com -c user.name=T commit -q -m "squash: parent"
    printf 'L1\nintegrated-by-another-pr\n' > shared.txt
    git -c user.email=t@e.com -c user.name=T commit -q -am "another PR edits shared.txt"
    git checkout -q feat/child
    _set_baseline_branch allprs feat/child "$parent_tip"

    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cd "$SOURCE_DIR"
    git cat-file -e allprs:child.txt
    git show allprs:shared.txt | grep -q "integrated-by-another-pr"
    run grep -q '^<<<<<<<' <(git show allprs:shared.txt)
    [ "$status" -ne 0 ]
    [ "$(git log -1 --pretty=%P allprs | wc -w)" -eq 1 ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

# #33: a GENUINE overlap (child's own delta collides with already-integrated work)
# must fail closed — clean tree, restored branch, step 16 unmarked.
@test "mergetoall.sh fails closed on genuine overlap, leaves no half-applied index (#33)" {
    cd "$SOURCE_DIR"
    git checkout -q main
    git checkout -q -b feat/parent
    printf 'L1\n' > shared.txt && git add shared.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m "parent: add shared.txt"
    parent_tip="$(git rev-parse HEAD)"
    git checkout -q -b feat/child
    printf 'L1-child\n' > shared.txt   # child itself EDITS shared.txt (real overlap)
    git -c user.email=t@e.com -c user.name=T commit -q -am "child: edit shared.txt"
    git checkout -q -b allprs main
    git merge --squash feat/parent >/dev/null
    git -c user.email=t@e.com -c user.name=T commit -q -m "squash: parent"
    printf 'L1-allprs\n' > shared.txt  # all_prs has a DIFFERENT edit → real conflict
    git -c user.email=t@e.com -c user.name=T commit -q -am "another PR edits shared.txt"
    git checkout -q feat/child
    _set_baseline_branch allprs feat/child "$parent_tip"

    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"genuine overlap"* ]]
    cd "$SOURCE_DIR"
    [ -z "$(git status --porcelain)" ]
    [ "$(git symbolic-ref --short HEAD)" = "feat/child" ]
    [ "$(git log -1 --pretty=%s allprs)" = "another PR edits shared.txt" ]
    grep -qE '^- \[ \] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

# #33: the NON-STACKED production path (baseline_sha SET) must be byte-identical to
# the old `git merge --squash`. The 7 existing tests ship baseline_sha="" so they only
# exercise the merge-base FALLBACK, not this primary path — this closes that gap.
# REGRESSION TRIPWIRE: do NOT "simplify" the fix back to `git merge --squash` — it
# reintroduces #33 (this byte-identical guard alone won't catch that; tests 9/10 will).
@test "mergetoall.sh non-stacked baseline_sha path is byte-identical to merge --squash (#33)" {
    cd "$SOURCE_DIR"
    git checkout -q main
    git checkout -q -b allprs
    base_sha="$(git rev-parse HEAD)"
    git checkout -q -b feat/solo
    echo solo > solo.txt && git add solo.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m "solo: add solo.txt"
    git checkout -q -b ref-allprs allprs
    git merge --squash feat/solo >/dev/null
    git -c user.email=devagent@local -c user.name=devagent commit -q -m "solo: add solo.txt"
    ref_tree="$(git rev-parse 'ref-allprs^{tree}')"
    git checkout -q feat/solo
    _set_baseline_branch allprs feat/solo "$base_sha"

    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cd "$SOURCE_DIR"
    [ "$(git rev-parse 'allprs^{tree}')" = "$ref_tree" ]
    [ "$(git log -1 --pretty=%P allprs | wc -w)" -eq 1 ]
    [ "$(git log -1 --pretty='%an|%cn' allprs)" = "devagent|devagent" ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh zero-diff guard rev-lists the issue branch, not source_dir HEAD (#68)" {
    # Same bug as ship.sh: rev-list HEAD ^baseline in source_dir. feat/1-x has a commit
    # but source_dir HEAD is detached at the baseline → HEAD ^baseline is empty → the
    # guard wrongly marks step 16 [-] and the branch is never squash-merged.
    base="$(cd "$SOURCE_DIR" && /usr/bin/git rev-parse feat/1-x~1)"     # feat/1-x's fork point
    ( cd "$SOURCE_DIR" && /usr/bin/git checkout -q "$base" )            # detach HEAD at baseline; HEAD != feat/1-x
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"$base\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"zero commits"* ]]                                 # NOT the zero-diff skip
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"   # merged, not [-]
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
}
