#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    echo "kernels: add NEONv8 FMA tier" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    # Stubs (all log via devagent_stub so devagent_assert_logged finds them).
    devagent_stub git ""
    devagent_stub gh "https://github.com/acme/testproj/pull/77"
    # Stub issue backend (separate dir override).
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "ship.sh pushes branch, creates MR, fires on_ship transition, stores mr_url" {
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin feat/1-x"
    devagent_assert_logged "gh pr create --repo acme/testproj"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_ship"
    grep -q 'mr_url *= *"https://github.com/acme/testproj/pull/77"' \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -qE '^- \[x\] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "ship.sh halts when push_mr=false and non-interactive (no DA_YES)" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    # Force closed stdin so confirm() sees non-tty regardless of how bats
    # itself was invoked. Without </dev/null this hangs when bats is run
    # from an interactive terminal (read -r -p blocks waiting for input).
    run bash -c "'$DEVAGENT_ROOT/scripts/ship.sh' '$TEST_PROJECT' Issue-1 </dev/null"
    [ "$status" -ne 0 ]
    # Checklist unchanged for step 15.
    grep -qE '^- \[ \] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
    # Plan was printed (the permission gate text goes to stderr; bats merges it into $output).
    [[ "$output" == *"ship plan"* ]]
    # No MR url recorded. (run+status, not vacuous `! grep`; checked after $output use.)
    run grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

@test "ship.sh proceeds when push_mr=false but DA_YES=1 bypasses" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    DA_YES=1 run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "ship.sh warns on unmerged deps but proceeds without --strict-deps" {
    DEVAGENT_STATE_DIR="$HOME/.claude/devagent/state" \
        "$DEVAGENT_ROOT/scripts/depends.sh" --project "$TEST_PROJECT" Issue-1 on Issue-99
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"Issue-99"* ]]
    grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "ship.sh blocks on unmerged deps when --strict-deps is set" {
    DEVAGENT_STATE_DIR="$HOME/.claude/devagent/state" \
        "$DEVAGENT_ROOT/scripts/depends.sh" --project "$TEST_PROJECT" Issue-1 on Issue-99
    run "$DEVAGENT_ROOT/scripts/ship.sh" --strict-deps "$TEST_PROJECT" Issue-1
    [ "$status" -eq 2 ]
    [[ "$output" == *"blocking ship"* ]]
    run grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

@test "ship.sh fork_only targets the fork and skips upstream transition" {
    # Enable fork_only on the test project.
    sed -i '/^\[project\.'"$TEST_PROJECT"'\]/a fork_only = true' "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # MR targets the fork
    devagent_assert_logged "gh pr create --repo me/testproj"
    [[ "$output" == *"skipping on_ship transition"* ]]
    # Upstream issue transition skipped (key fork_only invariant; run+status, checked after $output use).
    devagent_refute_logged "issue/github transition"
}

@test "ship.sh fork_only without code_source.fork dies" {
    sed -i '/^fork *=/d' "$HOME/.claude/devagent/config.toml"
    sed -i '/^\[project\.'"$TEST_PROJECT"'\]/a fork_only = true' "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"fork_only=true requires code_source.fork"* ]]
}

@test "ship.sh routes Issue-Fork-* transition to issue_source_fork tracker" {
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.$TEST_PROJECT.issue_source_fork]
backend = "github"
repo    = "me/testproj"
EOF
    mkdir -p "$DEVDOC_DIR/Issue-Fork-51"
    echo "MR body" > "$DEVDOC_DIR/Issue-Fork-51/mr.md"
    echo "fork issue title" > "$DEVDOC_DIR/Issue-Fork-51/.devagent-title"
    bash "$DEVAGENT_ROOT/scripts/checklist-init.sh" --template standard \
        "$DEVDOC_DIR/Issue-Fork-51"
    sed -i "s|^active_issue *=.*|active_issue = \"Issue-Fork-51\"|; \
            s|^issue_dir *=.*|issue_dir    = \"$DEVDOC_DIR/Issue-Fork-51\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/fork-51 \
        && echo x >a.txt && git add a.txt \
        && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
    sed -i "s|^branch *=.*|branch = \"feat/fork-51\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-Fork-51
    [ "$status" -eq 0 ]
    devagent_assert_logged "issue/github transition me/testproj 51 on_ship"
    devagent_refute_logged "issue/github transition acme/testproj"
}

@test "ship.sh skips transition for Issue-Fork-* with no issue_source_fork configured" {
    mkdir -p "$DEVDOC_DIR/Issue-Fork-51"
    echo "MR body" > "$DEVDOC_DIR/Issue-Fork-51/mr.md"
    echo "fork issue title" > "$DEVDOC_DIR/Issue-Fork-51/.devagent-title"
    bash "$DEVAGENT_ROOT/scripts/checklist-init.sh" --template standard \
        "$DEVDOC_DIR/Issue-Fork-51"
    sed -i "s|^active_issue *=.*|active_issue = \"Issue-Fork-51\"|; \
            s|^issue_dir *=.*|issue_dir    = \"$DEVDOC_DIR/Issue-Fork-51\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/fork-51 \
        && echo x >a.txt && git add a.txt \
        && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
    sed -i "s|^branch *=.*|branch = \"feat/fork-51\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-Fork-51
    [ "$status" -eq 0 ]
    [[ "$output" == *"no issue tracker configured for Issue-Fork-51"* ]]
    devagent_refute_logged "issue/github transition"
}

@test "ship.sh reads PR title from .devagent-title, not mr.md line 1" {
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "kernels: add NEONv8 FMA tier"
}

@test "ship.sh opens draft PR when .devagent-draft marker is present" {
    touch "$DEVDOC_DIR/Issue-1/.devagent-draft"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "--draft"
}

# include_coauthor strip-guard (#31). The default `gh` stub records argv only, so
# these install a body-capturing stub that also logs the --body-file CONTENTS,
# bracketed by BODYSTART/BODYEND, so the test can assert on the PR body itself.
# NB: `! cmd | grep` is vacuous under bats; use run + status for the negative.
_install_body_capturing_gh_stub() {
    cat > "$DEVAGENT_STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
printf '%s' gh >> "$DEVAGENT_STUB_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$DEVAGENT_STUB_LOG"; done
printf '\n' >> "$DEVAGENT_STUB_LOG"
prev=""
for a in "\$@"; do
  [ "\$prev" = "--body-file" ] && printf 'BODYSTART\n%s\nBODYEND\n' "\$(cat "\$a")" >> "$DEVAGENT_STUB_LOG"
  prev="\$a"
done
printf '%s' "https://github.com/acme/testproj/pull/77"
STUB
    chmod +x "$DEVAGENT_STUB_BIN/gh"
}

@test "ship.sh strips Co-Authored-By from PR body when include_coauthor=false; mr.md untouched" {
    sed -i '/^\[project\.'"$TEST_PROJECT"'\]/a include_coauthor = false' \
        "$HOME/.claude/devagent/config.toml"
    printf '%s\n' 'PR summary' '' 'Co-Authored-By: Claude <noreply@anthropic.com>' \
        > "$DEVDOC_DIR/Issue-1/mr.md"
    _install_body_capturing_gh_stub

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    body_sent="$(sed -n '/BODYSTART/,/BODYEND/p' "$DEVAGENT_STUB_LOG")"
    # The body handed to create-mr has NO co-author line...
    run grep -qi "co-authored-by" <<<"$body_sent"
    [ "$status" -ne 0 ]
    echo "$body_sent" | grep -q "PR summary"
    # ...but mr.md on disk is the durable record and stays untouched.
    grep -qi "co-authored-by" "$DEVDOC_DIR/Issue-1/mr.md"
}

@test "ship.sh keeps Co-Authored-By in PR body when include_coauthor unset (default true)" {
    printf '%s\n' 'PR summary' '' 'Co-Authored-By: Claude <noreply@anthropic.com>' \
        > "$DEVDOC_DIR/Issue-1/mr.md"
    _install_body_capturing_gh_stub

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    body_sent="$(sed -n '/BODYSTART/,/BODYEND/p' "$DEVAGENT_STUB_LOG")"
    echo "$body_sent" | grep -qi "co-authored-by"
}

@test "ship.sh fails closed when the body is empty after coauthor strip (#31)" {
    sed -i '/^\[project\.'"$TEST_PROJECT"'\]/a include_coauthor = false' \
        "$HOME/.claude/devagent/config.toml"
    # Pathological: mr.md is ONLY a trailer + blank lines → empty after strip.
    printf '%s\n' '' 'Co-Authored-By: Claude <noreply@anthropic.com>' '' \
        > "$DEVDOC_DIR/Issue-1/mr.md"
    _install_body_capturing_gh_stub

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty after Co-Authored-By strip"* ]]
    # Fail-closed: no PR was created, no mr_url recorded. (run+status, not `! grep`,
    # which is vacuous under bats — the `!` exempts it from the failure trap.)
    devagent_refute_logged "gh pr create"
    run grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

@test "ship.sh bases a stacked-child PR on the parent branch, not default_baseline (#34)" {
    # Install a real-git-EXCEPT-push stub FIRST — setup() stubs git to "", which
    # would make the topology-building git commands below no-ops. With this stub,
    # for-each-ref/rev-list/checkout/commit run for real; only `push` is intercepted
    # (no remote in the test repo). gh is stubbed to capture --base.
    cat > "$DEVAGENT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "git push \$*" >> "$DEVAGENT_STUB_LOG"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/git"
    devagent_stub gh "https://github.com/acme/testproj/pull/77"
    # Topology: main → feat/parent → feat/child (stacked). main is the test repo's
    # default branch (devagent_test_setup inits with init.defaultBranch=main).
    cd "$SOURCE_DIR"
    git checkout -q main
    git checkout -q -b feat/parent
    echo p > p.txt && git add p.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m parent
    parent_tip="$(git rev-parse HEAD)"
    git checkout -q -b feat/child
    echo c > c.txt && git add c.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m child
    sed -i "s|^branch *=.*|branch = \"feat/child\"|; \
            s|^baseline_sha *=.*|baseline_sha = \"$parent_tip\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    echo "child title" > "$DEVDOC_DIR/Issue-1/.devagent-title"

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # PR opened against the parent branch ...
    grep -qE "gh pr create .* --base feat/parent( |$)" "$DEVAGENT_STUB_LOG"
    # ... NOT the default base. (run+status, not vacuous `! grep`.)
    run grep -qE "gh pr create .* --base main( |$)" "$DEVAGENT_STUB_LOG"
    [ "$status" -ne 0 ]
}

# --- #148: modified-tracked-files gate -------------------------------------
# Review (13) / redmr (14) fixes applied after commit (10) used to strand in
# the working tree; ship.sh pushed the branch without them. The gate refuses
# to push when tracked files are modified in work_dir; untracked-only noise
# (build dirs, scratch files) still ships. Uses the real-git-except-push stub
# so `git status --porcelain` reflects the actual tree.
_install_real_git_except_push_stub() {
    cat > "$DEVAGENT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "git push \$*" >> "$DEVAGENT_STUB_LOG"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/git"
}

@test "ship.sh refuses to push when tracked files are modified (#148)" {
    _install_real_git_except_push_stub
    echo "stranded review fix" >> "$SOURCE_DIR/a.txt"   # tracked, modified, uncommitted
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"modified tracked file"* ]]
    # Fail-closed: no PR, no mr_url, step 15 untouched. (run+status, not
    # vacuous `! grep` — see SC2314 gate.)
    devagent_refute_logged "gh pr create"
    run grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
    grep -qE '^- \[ \] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "ship.sh ships clean when only untracked files are present (#148)" {
    _install_real_git_except_push_stub
    echo scratch > "$SOURCE_DIR/scratch.tmp"            # untracked-only noise
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr create --repo acme/testproj"
    grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "ship.sh dies fail-closed when worktree_path points at a dead tree (#148)" {
    _install_real_git_except_push_stub
    # Stale worktree_path (state-race / pruned-worktree scenario): the gate must
    # refuse loudly, not silently no-op against a path git cannot inspect.
    state_file="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    if grep -q '^worktree_path' "$state_file"; then
        sed -i "s|^worktree_path *=.*|worktree_path = \"$DEVAGENT_TMP/gone-worktree\"|" "$state_file"
    else
        # Insert BEFORE [parked] — a bare append would land inside that table
        # (the exact key-placement bug class from the audit) and be invisible
        # to a top-level state_get.
        sed -i "/^\[parked\]/i worktree_path = \"$DEVAGENT_TMP/gone-worktree\"" "$state_file"
    fi
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a usable git tree"* ]]
    devagent_refute_logged "gh pr create"
    run grep -q '^mr_url' "$state_file"
    [ "$status" -ne 0 ]
}

@test "ship.sh zero-diff auto-skip fires before the #148 gate (dirty tree, no commits)" {
    _install_real_git_except_push_stub
    # baseline = branch tip → rev-list empty → artifact-only auto-skip path,
    # even though the tree is dirty (devdoc-style edits must not block it).
    tip="$(cd "$SOURCE_DIR" && /usr/bin/git rev-parse HEAD)"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"$tip\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "dirty" >> "$SOURCE_DIR/a.txt"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"zero-diff"* ]]
    grep -qE '^- \[-\] +15\. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
    devagent_refute_logged "gh pr create"
}

@test "ship.sh falls back to default base with a warning when the stacked parent is absent on the target repo (#41)" {
    # Same topology as the #34 test, but gh's `api` (branch-exists) reports the
    # parent ABSENT (exit 1) → ship must base on the default base + warn, not
    # surface a raw gh error or base on the missing parent.
    cat > "$DEVAGENT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then echo "git push \$*" >> "$DEVAGENT_STUB_LOG"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/git"
    cat > "$DEVAGENT_STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then exit 1; fi          # branch-exists → absent
echo "gh \$*" >> "$DEVAGENT_STUB_LOG"
printf '%s' "https://github.com/acme/testproj/pull/77"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/gh"
    cd "$SOURCE_DIR"
    git checkout -q main
    git checkout -q -b feat/parent
    echo p > p.txt && git add p.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m parent
    parent_tip="$(git rev-parse HEAD)"
    git checkout -q -b feat/child
    echo c > c.txt && git add c.txt
    git -c user.email=t@e.com -c user.name=T commit -q -m child
    sed -i "s|^branch *=.*|branch = \"feat/child\"|; \
            s|^baseline_sha *=.*|baseline_sha = \"$parent_tip\"|" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    echo "child title" > "$DEVDOC_DIR/Issue-1/.devagent-title"

    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found on"* ]]                                # the #41 warning fired
    grep -qE "gh pr create .* --base main( |$)" "$DEVAGENT_STUB_LOG"   # fell back to the default base
    run grep -qE "gh pr create .* --base feat/parent( |$)" "$DEVAGENT_STUB_LOG"
    [ "$status" -ne 0 ]                                                # NOT the absent parent
}
