#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # #231/#242: a valid close requires the closeout steps terminal; mark
    # updatewbs/impact/lessonslearned [x] so the pre-existing cleanup tests
    # exercise the allowed path. Whitespace-robust: key on the line content,
    # edit the glyph in place (don't assume spacing).
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 x
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
    # #586: the register must resolve to a FIXTURE (never the plugin default —
    # the drain would write the repo's real templates/potholes.md). Written
    # BEFORE the devdoc seed commit so the existing tests' devdoc diff is
    # unchanged. Seed citations are never Issue-1 (the issue under test).
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '# Pothole register' '' \
        '## Bash exit-status & control flow' '- an existing line (Issue-7).' '' \
        '## Docs / edit-neighborhood hygiene' '- another existing line (Issue-8).' \
        > "$DEVDOC_DIR/templates/potholes.md"
    export TEMPLATE_PATHS_OVERRIDE_potholes="$DEVDOC_DIR/templates/potholes.md"
    # #611: the seed is a fixture too — a full COPY of the plugin templates with
    # only potholes.md replaced, so every other key still resolves.
    export DEVAGENT_PLUGIN_TEMPLATES="$DEVAGENT_TMP/plugin_templates"
    cp -r "$DEVAGENT_ROOT/templates" "$DEVAGENT_PLUGIN_TEMPLATES"
    cp "$DEVDOC_DIR/templates/potholes.md" "$DEVAGENT_PLUGIN_TEMPLATES/potholes.md"
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

# #611: a line staged for the PROJECT layer (the devdoc register the setup committed).
stage_in_project_layer() {
    bash "$DEVAGENT_ROOT/scripts/promote-potholes.sh" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-1" \
        --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
}

@test "cleanup.sh switches source tree to main, commits devdoc, clears active_issue" {
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "main" ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -ge 2 ]
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "cleanup.sh skips devdoc commit when commit_devdoc=false" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}

@test "cleanup names the PINNED issue (not the shared slot) in the devdoc commit (#331)" {
    # Shared slot stays Issue-1; a pinned session cleans up Issue-2. The devdoc
    # commit message (from issue_arg) must name Issue-2 — before the fix issue_arg
    # was arg→SHARED state = Issue-1, naming the other session's issue.
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    msg="$( cd "$DEVDOC_DIR" && git log -1 --format='%s' )"
    [[ "$msg" == *"Issue-2"* ]]
    [[ "$msg" != *"Issue-1 cleanup"* ]]
}

@test "cleanup.sh commits an entirely-untracked (fresh) issue dir (#140)" {
    # A fresh Issue-2 dir created this cycle is fully untracked; with
    # commit_devdoc=true the auto-commit must still see it (the old tracked-only
    # diff guard was blind to untracked files).
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" active_issue "Issue-2"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" issue_dir "$DEVDOC_DIR/Issue-2"
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
    # Mark every step except step 23 done in the seeded checklist;
    # cleanup will mark step 23 itself, then call wbs update.
    sed -i 's/^- \[ \]\([ ]*\([0-9]*\)\.\)/- [x]\1/' \
        "$DEVDOC_DIR/Issue-1/checklist.md"
    # Re-mark step 23 as pending so cleanup has work to do.
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' '
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
    # cleanup marks its own step 23, then calls wbs update, which sees
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
    # Quoted "23" is deliberate: cleanup re-sets last_step via the string-typed
    # state_set AFTER the clear, preserving today's stored form exactly.
    grep -qE '^last_step = "23"$' "$f"
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

@test "cleanup.sh blocks when lessonslearned is pending (#231)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 ' '
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *lessonslearned* ]]
    # fail-closed: no side effects — step 23 still pending, branch unchanged
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]
}

@test "cleanup.sh proceeds when lessonslearned is skipped [-] (#231)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 '-'
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "cleanup.sh proceeds when the checklist has no lessonslearned step (#231)" {
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 22
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

# --- #242: generalized closeout gate ----------------------------------------

@test "cleanup dies naming ALL non-terminal closeout steps (#242)" {
    # Re-pend 17 and 18 (setup marked them [x]); 19 stays [x].
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 ' '
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 ' '
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"updatewbs:[ ]"* ]]
    [[ "$output" == *"impact:[ ]"* ]]
    # No side effect ran: step 23 unmarked, source repo still on the branch.
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "feat/1-x" ]
}

@test "cleanup proceeds when closeout steps are [x]/[-] mixed (#242)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 '-'
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "cleanup: absent closeout steps do not gate (#242)" {
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 20
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 21
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 22
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "cleanup.sh removes the issue's keyed analyze build dirs, sparing siblings (#351)" {
    key="$(printf '%s-%s' "$TEST_PROJECT" "Issue-1" | tr -c 'A-Za-z0-9' '-')"
    mkdir -p "$SOURCE_DIR/build-$key" "$SOURCE_DIR/build-$key-asan" "$SOURCE_DIR/build-$key-tsan"
    # A different issue's dir whose key is a PREFIX (Issue-1 vs Issue-10) must survive.
    mkdir -p "$SOURCE_DIR/build-${TEST_PROJECT}-Issue-10-asan"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -d "$SOURCE_DIR/build-$key" ]
    [ ! -d "$SOURCE_DIR/build-$key-asan" ]
    [ ! -d "$SOURCE_DIR/build-$key-tsan" ]
    [ -d "$SOURCE_DIR/build-${TEST_PROJECT}-Issue-10-asan" ]   # prefix guard: not wiped
}

@test "unpinned cleanup of a NON-active issue leaves the shared slot intact (#417)" {
    # Shared slot owns Issue-1 (from setup) with its live top-level branch context.
    # Clean a DIFFERENT issue (Issue-2) from an UNPINNED session: the shared slot
    # and Issue-1's context must survive (the old guard keyed on pin-absence and
    # wiped them).
    mkdir -p "$DEVDOC_DIR/Issue-2"
    cp "$DEVDOC_DIR/Issue-1/checklist.md" "$DEVDOC_DIR/Issue-2/checklist.md"
    ( cd "$DEVDOC_DIR" && git add . && git commit -q -m "seed Issue-2" )
    unset DEVAGENT_ACTIVE_ISSUE
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-2
    [ "$status" -eq 0 ]
    # active_issue pointer + Issue-1's top-level branch mirror untouched.
    grep -q '^active_issue *= *"Issue-1"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '^branch *= *"feat/1-x"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "#418: cleanup clears+stamps+resets in ONE transaction — no crash window" {
    # Shim python3 to log every _toml.py argv, then exec the real interpreter.
    REAL_PY="$(command -v python3)"
    mkdir -p "$DEVAGENT_TMP/shim"
    cat > "$DEVAGENT_TMP/shim/python3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DEVAGENT_TMP/toml-calls.log"
exec "$REAL_PY" "\$@"
SH
    chmod +x "$DEVAGENT_TMP/shim/python3"
    : > "$DEVAGENT_TMP/toml-calls.log"
    PATH="$DEVAGENT_TMP/shim:$PATH" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # ONE transact carries BOTH the pointer clear (active_issue) AND the per-issue
    # reset (branch) — proving the clear+set is a single atomic call, not two.
    fused="$(grep 'transact' "$DEVAGENT_TMP/toml-calls.log" | grep 'active_issue' | grep 'branch')"
    [ -n "$fused" ]
    # The old separate set-many writing active_issue is gone.
    run bash -c "grep -c 'set-many .*active_issue' '$DEVAGENT_TMP/toml-calls.log'"
    [ "$output" -eq 0 ]
    # Behavior unchanged: pointer cleared + closeout stamped.
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '^last_step_name *= *"cleanup"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "#586: cleanup DIES before the tree restore when a promotion claim is unbacked" {
    printf '%s\n' '- 2026-08-01 10:00  lessonslearned: lessonsLearned.md written: 4 entries; 2 patterns promoted to potholes register' \
        >> "$DEVDOC_DIR/Issue-1/checklist.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"CLAIMS a register promotion"* ]]
    # died BEFORE the side effect: the tree is still on the issue branch
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "feat/1-x" ]
}

@test "#586/#611: cleanup drains a PENDING promotion after the restore, committing the devdoc register ITSELF, then its own devdoc commit carries the rest" {
    stage_in_project_layer
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q 'a neutral line (Issue-1).' "$DEVDOC_DIR/templates/potholes.md"
    run bash -c "cd '$DEVDOC_DIR' && git log -2 --format='%s|%ae'"
    [ "${lines[0]}" = "devdoc: Issue-1 cleanup|devagent@local" ]
    [ "${lines[1]}" = "chore: promote pothole-register entries from #1|t@example.com" ]
    run bash -c "cd '$DEVDOC_DIR' && git show --stat --format= HEAD"
    [[ "$output" != *"templates/potholes.md"* ]]           # never via cleanup's git add -A
    run bash -c "cd '$DEVDOC_DIR' && git show --stat --format= HEAD~1"
    [[ "$output" == *"templates/potholes.md"* ]]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "main" ]
    grep -q '^status: applied' "$DEVDOC_DIR/Issue-1/potholes-promotion.md"
}

@test "#611: end-to-end on a FRESH project with no layer file — --add then cleanup bootstraps, lands and commits in one run" {
    rm -f "$DEVDOC_DIR/templates/potholes.md"; ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "no register" )
    stage_in_project_layer
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/templates/potholes.md" ]
    grep -q 'a neutral line (Issue-1).' "$DEVDOC_DIR/templates/potholes.md"
    run bash -c "cd '$DEVDOC_DIR' && git log --format=%s | grep -c 'promote pothole-register'"
    [ "$output" = "1" ]
    run bash -c "cd '$DEVDOC_DIR' && git status --porcelain"
    [ -z "$output" ]
}

@test "#586/#611: a DEFERRED drain (dirty register) warns and completes cleanup" {
    stage_in_project_layer
    printf '%s\n' '- foreign (Issue-3).' >> "$DEVDOC_DIR/templates/potholes.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]                       # a deferral is not a failure
    [[ "$output" == *pending* ]]
    [[ "$output" == *"--drop"* ]]             # #612: the multi-cause message names the op-validation close too
    [[ "$output" == *"register-contract violation"* ]]   # #613: and the file-contract class, with its by-hand remedy
    grep -q '^status: pending' "$DEVDOC_DIR/Issue-1/potholes-promotion.md"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    # #611 review: the DEFERred layer file is NOT swept by cleanup's own devdoc commit
    run bash -c "cd '$DEVDOC_DIR' && git log -1 --format=%s"
    [ "$output" = "devdoc: Issue-1 cleanup" ]
    run bash -c "cd '$DEVDOC_DIR' && git show --stat --format= HEAD"
    [[ "$output" != *"templates/potholes.md"* ]]
    run bash -c "cd '$DEVDOC_DIR' && git status --porcelain -- templates/potholes.md"
    [[ "$output" == " M templates/potholes.md" ]]            # the foreign edit is still theirs to commit
}

@test "#611: commit_devdoc=false → the drain DEFERS naming the flag and cleanup completes without any devdoc commit" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    stage_in_project_layer
    before="$(cd "$DEVDOC_DIR" && git rev-parse HEAD)"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *commit_devdoc* ]]
    [ "$(cd "$DEVDOC_DIR" && git rev-parse HEAD)" = "$before" ]
}

@test "#611 red-team: a FAILED layer lookup refuses the devdoc commit instead of re-arming the sweep" {
    devagent_config_set "$HOME/.claude/devagent/config.toml" paths.potholes_workflow "relative/wf.md"   # relative global key → resolver dies
    printf '%s\n' '- foreign (Issue-3).' >> "$DEVDOC_DIR/templates/potholes.md"
    before="$(cd "$DEVDOC_DIR" && git rev-parse HEAD)"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"devdoc commit REFUSED"* ]]
    [ "$(cd "$DEVDOC_DIR" && git rev-parse HEAD)" = "$before" ]
    run bash -c "cd '$DEVDOC_DIR' && git status --porcelain -- templates/potholes.md"
    [[ "$output" == " M templates/potholes.md" ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "#611: cleanup's own devdoc commit never sweeps a dirty file OUTSIDE devdoc_dir (a workflow register at the repo root)" {
    parent="$DEVAGENT_TMP/devdoc"
    rm -rf "$DEVDOC_DIR/.git"
    ( cd "$parent" && git -c init.defaultBranch=main init -q && git config user.email t@example.com && git config user.name Test && git add -A && git commit -q -m seed )
    printf '# stray edit\n' > "$parent/templates-wf.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run bash -c "cd '$parent' && git status --porcelain"
    [[ "$output" == *"?? templates-wf.md"* ]]                # still untracked, not committed
    run bash -c "cd '$parent' && git log -1 --format=%s"
    [ "$output" = "devdoc: Issue-1 cleanup" ]
}

# --- #595: the oneshot no-repo-diff boundary gate -----------------------------

# A genuine oneshot issue: the real template's rows (0/9/11/22/23) with
# everything before cleanup terminal, so cleanup IS the current step. Built by
# the checklist-init.sh SUBPROCESS, never by sourcing checklist_init here.
make_oneshot_issue() {
    local d="$DEVDOC_DIR/Issue-1" s
    rm -f "$d/checklist.md"
    ISSUE_ID=Issue-1 bash "$DEVAGENT_ROOT/scripts/checklist-init.sh" --template oneshot --project "$TEST_PROJECT" "$d"
    for s in 0 9 11 22; do mark_step "$d/checklist.md" "$s" x; done
    ( cd "$SOURCE_DIR" && git checkout -q main \
      && git update-ref refs/remotes/origin/main "$(git rev-parse main)" )
}

@test "cleanup REFUSES a oneshot with an unpublished commit (#595 AC1)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && echo x > f.txt && git add f.txt \
      && git commit -q -m "the oneshot committed" )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"oneshot boundary VIOLATED"* ]]
    [[ "$output" == *"--retier standard"* ]]
    # Refused BEFORE any side effect: step unmarked, devdoc untouched, so the
    # re-run after a retier starts clean.
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}

@test "cleanup REFUSES a oneshot with a dirty tree (#595 AC1)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && echo changed >> README.md )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"oneshot boundary VIOLATED"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "cleanup REFUSES on indeterminate — fail-safe (#595 AC3)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && git update-ref -d refs/remotes/origin/main )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"INDETERMINATE"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "cleanup COMPLETES a clean oneshot (#595 AC2)" {
    make_oneshot_issue
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "a bare cleanup re-run after a clean oneshot close still completes (#595 redmr M1)" {
    # After state_cleanup_finish active_issue is "" and issue_dir is left
    # standing; pre-#595 a bare re-run completed on that slot, and the gate
    # must not turn it into 'could not RUN (rc=1)'.
    make_oneshot_issue
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"could not RUN"* ]]
    [[ "$output" == *"oneshot-zerodiff: clean"* ]]
}

@test "cleanup COMPLETES an acknowledged oneshot, loudly (#595 seam)" {
    make_oneshot_issue
    printf 'deploy target, not git-measurable\n' \
        > "$DEVDOC_DIR/Issue-1/.devagent-oneshot-ack"
    ( cd "$SOURCE_DIR" && echo x > f.txt && git add f.txt && git commit -q -m c )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT CHECKED"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "a standard-tier cleanup spawns no checker at all (#595 AC2, r1 SE1/SE2)" {
    # The positive-capability control (register Issue-107), and the tier read
    # lives in cleanup.sh, so a non-oneshot close must not gain even the
    # checker's n/a line.
    grep -q '^Template: standard$' "$DEVDOC_DIR/Issue-1/checklist.md"
    ( cd "$SOURCE_DIR" && echo dirty >> README.md )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"oneshot-zerodiff"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "an --auto chain STOPS on the oneshot boundary refusal (#595 U3)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && echo x > f.txt && git add f.txt \
      && git commit -q -m "the oneshot committed" )
    run "$DEVAGENT_ROOT/scripts/next.sh" "$TEST_PROJECT" --auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"step 23 (cleanup), script-backed"* ]]
    [[ "$output" == *"oneshot boundary VIOLATED"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}
