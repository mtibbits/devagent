#!/usr/bin/env bats
# #595: the oneshot no-repo-diff boundary checker. One planted control per
# verdict class and per indeterminate CAUSE — a detector with N classes needs
# a control per class, not just the dramatic one (register volk Issue-Fork-162).
load 'helpers/common'

setup() {
    devagent_test_setup
    # The fixture configures default_baseline=origin/main but creates no remote;
    # mint the ref so the basis resolves (U2).
    ( cd "$SOURCE_DIR" && git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)" )
    sed -i 's/^Template: .*/Template: oneshot/' "$DEVDOC_DIR/Issue-1/checklist.md"
}
teardown() { devagent_test_teardown; }

CHK() { run "$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh" "$TEST_PROJECT" Issue-1; }

@test "clean tree on the base branch is clean, rc 0 (#595 AC2)" {
    CHK
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
    [[ "$output" == *"basis=origin/main@"* ]]
    [[ "$output" == *"branch=main"* ]]
}

@test "a tree merely BEHIND the base is still clean (#595 AC2, U1)" {
    # The false-positive control: not having pulled must not read as a violation.
    ( cd "$SOURCE_DIR" && echo up > up.txt && git add up.txt && git commit -q -m up \
      && git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)" && git reset -q --hard HEAD~1 )
    CHK
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
}

@test "TWELVE unpublished commits: rc 3 and the retier directive survives (#595 AC1, r2 B2)" {
    # Past ten commits a `git log | head` under pipefail died with SIGPIPE (141)
    # before printing the remedies. Twelve commits, and the directive must be
    # in the output.
    ( cd "$SOURCE_DIR" && for i in $(seq 1 12); do echo "$i" > "f$i"; git add "f$i"; git commit -q -m "c$i"; done )
    CHK
    [ "$status" -eq 3 ]
    [[ "$output" == *"oneshot-zerodiff: violated"* ]]
    [[ "$output" == *"--retier standard"* ]]
    [[ "$output" == *"RESTARTS THE ISSUE AT DRAFT"* ]]
    [[ "$output" == *"DOES NOT ASSERT"* ]]
}

@test "a TRACKED modification is violated, rc 3 (#595 AC1, U1)" {
    # zero_diff_classify reads `empty` here (measured) — this row is the reason
    # the separate status probe exists at all.
    ( cd "$SOURCE_DIR" && echo changed >> README.md )
    CHK
    [ "$status" -eq 3 ]
    [[ "$output" == *"uncommitted paths"* ]]
}

@test "an UNTRACKED new file is violated, rc 3 (#595 AC1)" {
    ( cd "$SOURCE_DIR" && echo scratch > newfile.txt )
    CHK
    [ "$status" -eq 3 ]
}

@test "a GITIGNORED path does not trip the guard — the declared LIMIT (#595)" {
    # A LIMITS sentence is itself a claim: construct the input it describes and
    # run the guard on it (register Issue-583).
    ( cd "$SOURCE_DIR" && printf 'build-*/\n' > .gitignore && git add .gitignore && git commit -q -m ign \
      && git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)" && mkdir -p build-x && echo o > build-x/o.txt )
    CHK
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
}

@test "tree on a SIBLING branch: indeterminate rc 4, names both branches, never violated (#595 r2 B4/B5)" {
    # The gate's ROUTINE trigger. From another branch published state cannot
    # be judged; the sibling's live work must not be reported as this issue's.
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/9-sibling && echo s > s.txt && git add s.txt && git commit -q -m sibling )
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"oneshot-zerodiff: indeterminate"* ]]
    [[ "$output" == *"branch=feat/9-sibling"* ]]
    [[ "$output" == *"checkout 'main'"* ]]
    [[ "$output" != *"violated"* ]]
}

@test "an UNRESOLVABLE default_baseline is indeterminate, never clean (#595 AC3)" {
    # The fail-open this design exists to avoid: baseline_resolve() would fall
    # back to HEAD here (baseline.sh:106-107) and print `clean`.
    ( cd "$SOURCE_DIR" && git update-ref -d refs/remotes/origin/main )
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"unresolved"* ]]
    [[ "$output" != *"oneshot-zerodiff: clean"* ]]
}

@test "an UNSET default_baseline is indeterminate, rc 4 (#595 AC3)" {
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.default_baseline"
    CHK
    [ "$status" -eq 4 ]
}

@test "a source_dir that is not a git tree is indeterminate, NOT rc 1 (#595 r1 SE4)" {
    d="$DEVAGENT_TMP/nonrepo"; mkdir -p "$d"
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.source_dir" "$d"
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"not a git work tree"* ]]
}

@test "a stale recorded worktree_path is indeterminate, NOT rc 1 (#595 r2 B6)" {
    # active_tree_resolve's OTHER die branch (active.sh:384-385), reachable
    # after `--retier oneshot` on a project that already ran step 8.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" context.Issue-1.worktree_path "$DEVAGENT_TMP/gone-worktree"
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"worktree_path"* ]]
}

@test "a VALID linked worktree_path is indeterminate; remedy is the tier, not a checkout (#595 review I3)" {
    # `git checkout main` in a linked worktree fails ('already used by
    # worktree'), so the routine remedy must not be the one printed here.
    ( cd "$SOURCE_DIR" && git worktree add -q "$DEVAGENT_TMP/wt" -b feat/1-linked )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" context.Issue-1.worktree_path "$DEVAGENT_TMP/wt"
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"tree=$DEVAGENT_TMP/wt"* ]]
    [[ "$output" == *"LINKED git worktree"* ]]
    [[ "$output" == *"--retier standard"* ]]
    [[ "$output" == *"worktree remove"* ]]
    [[ "$output" != *"checkout 'main'"* ]]
    [[ "$output" != *"violated"* ]]
}

@test "a VALID separate-clone worktree_path is the MEASURED tree, per the #571 contract (#595 review I2)" {
    # commit/ship/run-suite/preship-evidence all act on the recorded tree; the
    # gate measures the same one and stamps it. source_dir's own state is out of
    # scope in this shape — documented in the script's LIMITS.
    git clone -q "$SOURCE_DIR" "$DEVAGENT_TMP/clone"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" context.Issue-1.worktree_path "$DEVAGENT_TMP/clone"
    ( cd "$SOURCE_DIR" && echo changed >> README.md )
    CHK
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
    [[ "$output" == *"tree=$DEVAGENT_TMP/clone"* ]]
}

@test "bare invocation after a close reads the shared issue_dir slot — clean, rc 0 (#595 redmr M1)" {
    # state_cleanup_finish blanks active_issue and leaves issue_dir (active.sh:
    # "deliberately unchanged"); cleanup.sh's bare re-run follows issue_dir, so
    # the checker must too — it died rc 1 here, a regression on a clean tree.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue ""
    run "$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
}

@test "bare invocation with NO resolvable target is indeterminate, rc 4, never rc 1 (#595 redmr M1)" {
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue ""
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" issue_dir ""
    run "$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh" "$TEST_PROJECT"
    [ "$status" -eq 4 ]
    [[ "$output" == *"no issue to check"* ]]
}

@test "a malformed issue id is the one rc-1 shape: usage, not a verdict (#595)" {
    run "$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh" "$TEST_PROJECT" 'Issue-1/../Issue-2'
    [ "$status" -eq 1 ]
    [[ "$output" != *"oneshot-zerodiff:"* ]]
}

@test "a default_baseline with more than one slash is a documented LIMIT: permanent indeterminate (#595 redmr m1)" {
    # `${base_ref##*/}` keeps only the last segment — cleanup.sh's own
    # derivation, kept identical. Pinned so the LIMITS bullet stays a claim
    # with a row behind it (register Issue-583).
    ( cd "$SOURCE_DIR" && git checkout -q -b release/2.0 \
      && git update-ref refs/remotes/origin/release/2.0 "$(git rev-parse HEAD)" )
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.default_baseline" "origin/release/2.0"
    CHK
    [ "$status" -eq 4 ]
    [[ "$output" == *"branch=release/2.0"* ]]
    [[ "$output" == *"not the base branch '2.0'"* ]]
}

@test ".devagent-oneshot-ack is the acknowledged seam: rc 5, loud (#595)" {
    printf 'deploy target, not git-measurable\n' > "$DEVDOC_DIR/Issue-1/.devagent-oneshot-ack"
    ( cd "$SOURCE_DIR" && echo x > f.txt && git add f.txt && git commit -q -m c )
    CHK
    [ "$status" -eq 5 ]
    [[ "$output" == *"oneshot-zerodiff: acknowledged"* ]]
    [[ "$output" == *"not git-measurable"* ]]
}

@test "an EMPTY ack file does not silence the check (#595)" {
    # `-s` not `-e`: a zero-byte file is an accident, not consent.
    : > "$DEVDOC_DIR/Issue-1/.devagent-oneshot-ack"
    ( cd "$SOURCE_DIR" && echo x > f.txt && git add f.txt && git commit -q -m c )
    CHK
    [ "$status" -eq 3 ]
}

@test "non-oneshot tier is n/a and rc 0 (#595 AC2)" {
    sed -i 's/^Template: .*/Template: standard/' "$DEVDOC_DIR/Issue-1/checklist.md"
    CHK
    [ "$status" -eq 0 ]
    [[ "$output" == *"oneshot-zerodiff: n/a"* ]]
}

@test "source pin: active_tree_resolve's die set is exactly the pre-flighted one (#595 redmr m2)" {
    # The checker's "cannot die" claim is true only while active_tree_resolve
    # has exactly these die calls (stale worktree; source_dir unset; source_dir
    # missing), each excluded by the pre-flight. A fourth would surface as rc 1
    # in cleanup.sh's `*)` arm; make it redden here instead.
    run bash -c "awk '/^active_tree_resolve\(\)/,/^}/' '$DEVAGENT_ROOT/scripts/lib/active.sh' | grep -c 'die \"active_tree_resolve'"
    [ "$output" -eq 3 ]
}

@test "source pins: calls zero_diff_classify; no rev-list, no baseline_resolve, no early-closing pipe (#595)" {
    S="$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh"
    grep -qE '^ *\. .*lib/zerodiff\.sh' "$S"
    grep -qE '^ *verdict=.*zero_diff_classify' "$S"
    # `^[^#]*` — the token must appear on a CODE line, before any `#`: a
    # source-grep guard is matched by the prose that explains it (register
    # lectio Issue-6), and this file's header names all three tokens.
    run grep -nE '^[^#]*rev-list' "$S"
    [ "$status" -eq 1 ]
    run grep -nE '^[^#]*baseline_resolve' "$S"
    [ "$status" -eq 1 ]
    run grep -nE '^[^#]*\| *head ' "$S"
    [ "$status" -eq 1 ]
}
