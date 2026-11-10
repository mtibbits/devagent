#!/usr/bin/env bats
load 'helpers/common'
load 'helpers/devdoc-repo'

setup() {
    devagent_test_setup
    # #231/#242: a valid close requires the closeout steps terminal; mark
    # updatewbs/impact/lessonslearned [x] so the pre-existing cleanup tests
    # exercise the allowed path. Whitespace-robust: key on the line content,
    # edit the glyph in place (don't assume spacing).
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 21 x
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 x
    # #594: lessonslearned [x] means the file exists and lints clean — seeded
    # BEFORE the devdoc seed commit so the existing devdoc-diff assertions hold.
    seed_lessons_learned "$DEVDOC_DIR/Issue-1"
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
    seed_lessons_learned "$DEVDOC_DIR/Issue-2"   # #594: inherits lessonslearned [x]
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
    seed_lessons_learned "$DEVDOC_DIR/Issue-2"   # #594: inherits lessonslearned [x]
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
    # #703: the config's issue_source is a tracker source; a stub backend
    # reports Issue-1 closed (no real gh call).
    . "$BATS_TEST_DIRNAME/helpers/wbs-tracker.bash"
    export WBS_STUB_ROOT="$DEVAGENT_TMP"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/backends"
    wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
    printf '1\tdone\n' > "$DEVAGENT_TMP/state-list.github"
    # a github source needs `gh` on PATH to be looked up (no gh means "no
    # lookup", as on a gh-less box); the shim proves the stub made no call
    wbs_tracker_install_shims "$DEVAGENT_TMP/shims" "$DEVAGENT_TMP/network.log"
    PATH="$DEVAGENT_TMP/shims:$PATH" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -e "$DEVAGENT_TMP/network.log" ]
    # cleanup marks its own step 23, then calls wbs update, which takes
    # the tracker's closed state and flips the leaf to [x].
    grep -qxF -- '  - [x] Working leaf {issue: Issue-1, est: 1w, status_src: tracker}' "$DEVDOC_DIR/WBS.md"
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
    # Quoted "24" is deliberate: cleanup re-sets last_step via the string-typed
    # state_set AFTER the clear, preserving today's stored form exactly.
    grep -qE '^last_step = "24"$' "$f"
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
    seed_lessons_learned "$DEVDOC_DIR/Issue-2"   # #594: inherits lessonslearned [x]
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

@test "#611/#749: a FAILED layer lookup warns but still commits only the owned paths, never the layer" {
    devagent_config_set "$HOME/.claude/devagent/config.toml" paths.potholes_workflow "relative/wf.md"   # relative global key → resolver dies
    printf '%s\n' '- foreign (Issue-3).' >> "$DEVDOC_DIR/templates/potholes.md"
    before="$(cd "$DEVDOC_DIR" && git rev-parse HEAD)"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"register layer lookup failed"*"still takes only Issue-1's owned paths"* ]]
    [[ "$output" != *"REFUSED"* ]] || false
    [ "$(cd "$DEVDOC_DIR" && git rev-list --count "$before"..HEAD)" -eq 1 ]
    run git -C "$DEVDOC_DIR" show --name-only --format= HEAD
    [[ "$output" == *"Issue-1/checklist.md"* ]]
    [[ "$output" != *"potholes.md"* ]] || false
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

# A genuine oneshot issue: the real template's rows (0/9/11/23/24) with
# everything before cleanup terminal, so cleanup IS the current step. Built by
# the checklist-init.sh SUBPROCESS, never by sourcing checklist_init here.
make_oneshot_issue() {
    local d="$DEVDOC_DIR/Issue-1" s
    rm -f "$d/checklist.md"
    ISSUE_ID=Issue-1 bash "$DEVAGENT_ROOT/scripts/checklist-init.sh" --template oneshot --project "$TEST_PROJECT" "$d"
    for s in 0 9 11 23; do mark_step "$d/checklist.md" "$s" x; done
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 ' ' cleanup
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}

@test "cleanup REFUSES a oneshot with a dirty tree (#595 AC1)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && echo changed >> README.md )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"oneshot boundary VIOLATED"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 ' ' cleanup
}

@test "cleanup REFUSES on indeterminate — fail-safe (#595 AC3)" {
    make_oneshot_issue
    ( cd "$SOURCE_DIR" && git update-ref -d refs/remotes/origin/main )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"INDETERMINATE"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 ' ' cleanup
}

@test "cleanup COMPLETES a clean oneshot (#595 AC2)" {
    make_oneshot_issue
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 x cleanup
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 x cleanup
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
    [[ "$output" == *"step 24 (cleanup), script-backed"* ]]
    [[ "$output" == *"oneshot boundary VIOLATED"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 ' ' cleanup
}

# --- #594: the lessons-lint gate (keyed on the FILE, not the glyph) ------------

@test "cleanup REFUSES a red lessonsLearned.md, naming file and finding, before any side effect (#594)" {
    seed_red_lessons "$DEVDOC_DIR/Issue-1"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Issue-1/lessonsLearned.md"* ]]
    [[ "$output" == *"entry has no tag"* ]]
    [[ "$output" == *"(#594)"* ]]
    # The die precedes the tree restore: still on the issue branch, 23 unmarked.
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "feat/1-x" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "cleanup REFUSES lessonslearned [x] with NO lessonsLearned.md: a missing input is a failure (#594)" {
    rm -f "$DEVDOC_DIR/Issue-1/lessonsLearned.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"no lessonsLearned.md"* ]]
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "feat/1-x" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "cleanup proceeds when lessonslearned is skipped [-] and the file is absent (#594 skip seam)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 '-'
    rm -f "$DEVDOC_DIR/Issue-1/lessonsLearned.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "cleanup REFUSES a red lessonsLearned.md even under a [-] glyph: the gate is keyed on the file (#594)" {
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 '-'
    seed_red_lessons "$DEVDOC_DIR/Issue-1"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"entry has no tag"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "cleanup passes a lint-clean lessonsLearned.md and the closeout is unchanged (#594)" {
    before=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"lessons-lint"* ]]
    [ "$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )" -eq $((before + 1)) ]
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "main" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "the refusal's FIRST remedy works end to end: tag the entry, re-run, the closeout lands (#594)" {
    seed_red_lessons "$DEVDOC_DIR/Issue-1"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    # The message names the remedy it is about to be held to.
    [[ "$output" == *"- Tags: ["* ]]
    [[ "$output" == *"actionable reference norm pattern"* ]]
    # Execute it literally: an indented Tags line under the flat entry.
    printf '%s\n' '  - Tags: [pattern]' >> "$DEVDOC_DIR/Issue-1/lessonsLearned.md"
    before=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )" -eq $((before + 1)) ]
    [[ "$( cd "$DEVDOC_DIR" && git log -1 --format='%s' )" == *"Issue-1"* ]]
    ( cd "$DEVDOC_DIR" && git ls-files --error-unmatch Issue-1/lessonsLearned.md )
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "cleanup proceeds with NO lessonslearned row and no file: the glyph read is errexit-safe (#594)" {
    delete_step "$DEVDOC_DIR/Issue-1/checklist.md" 22
    rm -f "$DEVDOC_DIR/Issue-1/lessonsLearned.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "cleanup REFUSES when the lessons lint COULD NOT RUN: an unproven invariant does not close (#594)" {
    devagent_stub stub-lint "stub: cannot lint" 2
    LESSONS_LINT="$DEVAGENT_STUB_BIN/stub-lint" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not lint"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' ' cleanup
}

@test "the refusal's DE-SCOPING remedy works end to end: --by-name marks [-], the closeout lands (#594 review L1)" {
    # The skip remedy is a product surface like the first one: printed as a
    # pasteable command, so it is held to running as printed. Without --by-name
    # checklist-mark reads "lessonslearned" as a step NUMBER and exits 1.
    rm -f "$DEVDOC_DIR/Issue-1/lessonsLearned.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"checklist-mark --by-name"* ]]
    # Execute it literally, through the script the slash command wraps.
    run "$DEVAGENT_ROOT/scripts/checklist-mark.sh" --by-name "$DEVDOC_DIR/Issue-1" lessonslearned -
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 22 '-' lessonslearned
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

# ---- #885: self-marks by name -----------------------------------------------
@test "#885 cleanup marks its row by name on a checklist whose row number differs" {
    # A row inserted before updatewbs leaves cleanup at 24 (setup marked 20-22 [x];
    # the shift keeps their glyphs).
    shift_steps_from "$DEVDOC_DIR/Issue-1/checklist.md" updatewbs
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"refusing to mark"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 x cleanup
}

@test "#885 cleanup refuses while mergemr is [?], naming /devagent:mergemr" {
    # A mergemr row waiting on the PR (setup marked updatewbs..lessonslearned [x]; the
    # shift keeps their glyphs and leaves cleanup at 24).
    shift_steps_from "$DEVDOC_DIR/Issue-1/checklist.md" updatewbs
    sed -i -E 's/^(- \[.\] 19\. mergetoall)$/\1\n- [?] 20. mergemr/' "$DEVDOC_DIR/Issue-1/checklist.md"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 20 '?' mergemr
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"closeout steps not terminal: mergemr:[?]"* ]]
    [[ "$output" == *"run /devagent:mergemr first"* ]]
    # No side effect ran: cleanup unmarked, source repo still on the branch.
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 24 ' ' cleanup
    [ "$(cd "$SOURCE_DIR" && git branch --show-current)" = "feat/1-x" ]
}

@test "#885 a migrated checklist advances ship → mergemr → cleanup, each script marking by name" {
    # The setup's checklist is in the #558 scheme (closeout 20-23, no mergemr row).
    # Migrating it inserts mergemr at 20 and moves cleanup to 24; each script then
    # finds its own row by name. Zero-diff branch: ship auto-skips [-], so mergemr
    # takes rule 1 ([-], no PR) and nothing reaches a backend.
    local cl="$DEVDOC_DIR/Issue-1/checklist.md"
    local state="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    run bash "$DEVAGENT_ROOT/scripts/migrate-checklist-numbering.sh" "$DEVDOC_DIR/Issue-1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"+mergemr"* ]]
    assert_step "$cl" 20 ' ' mergemr
    assert_step "$cl" 24 ' ' cleanup
    devagent_state_set "$state" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse feat/1-x)"
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$cl" 18 '-' ship
    run "$DEVAGENT_ROOT/scripts/mergemr.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$cl" 20 '-' mergemr
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"refusing to mark"* ]]
    assert_step "$cl" 24 x cleanup
    assert_step "$cl" 21 x updatewbs
}

# --- #731: the transcript archive runs at cleanup when [archive] is configured ---

# _seed_transcript: one Claude Code session under a fixture CLAUDE_CONFIG_DIR.
_seed_transcript() {
    export CLAUDE_CONFIG_DIR="$DEVAGENT_TMP/claude"
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/c--src-x"
    printf '%s\n' '{"type":"assistant","sessionId":"S","message":{"id":"m1","usage":{"input_tokens":1},"content":[]}}' \
        > "$CLAUDE_CONFIG_DIR/projects/c--src-x/S.jsonl"
}

@test "cleanup.sh archives transcripts when [archive] is configured (#731)" {
    _seed_transcript
    printf '\n[archive]\ntranscripts_dir = "%s"\nhost_id = "h1"\n' "$DEVAGENT_TMP/archive" \
        >> "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVAGENT_TMP/archive/h1/c--src-x/S.jsonl.gz" ]
    [ -f "$DEVAGENT_TMP/archive/h1/last-run" ]
    [[ "$output" == *"h1: new 1, grown 0, unchanged 0, diverged 0, excluded 0"* ]]
}

# _prepend_config: put top-level keys before every table header of config.toml.
_prepend_config() {
    local cfg="$HOME/.claude/devagent/config.toml"
    { printf '%s\n' "$1"; cat "$cfg"; } > "$cfg.new" && mv "$cfg.new" "$cfg"
}

@test "cleanup.sh archives when [archive] is written as dotted keys (#731)" {
    _seed_transcript
    _prepend_config "archive.transcripts_dir = \"$DEVAGENT_TMP/archive\"
archive.host_id = \"h1\""
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVAGENT_TMP/archive/h1/c--src-x/S.jsonl.gz" ]
    [[ "$output" == *"h1: new 1, grown 0, unchanged 0, diverged 0, excluded 0"* ]]
}

@test "cleanup.sh archives when [archive] is written as an inline table (#731)" {
    _seed_transcript
    _prepend_config "archive = { transcripts_dir = \"$DEVAGENT_TMP/archive\", host_id = \"h1\" }"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVAGENT_TMP/archive/h1/c--src-x/S.jsonl.gz" ]
    [[ "$output" == *"h1: new 1, grown 0, unchanged 0, diverged 0, excluded 0"* ]]
}

@test "cleanup.sh warns once and completes when the archive fails (#731)" {
    _seed_transcript
    printf '\n[archive]\ntranscripts_dir = "%s"\nhost_id = "h1"\n' "$DEVDOC_DIR/archive" \
        >> "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'cleanup: transcript archive failed (non-fatal)')" -eq 1 ]
    [[ "$output" == *"is inside a git work tree"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ ! -e "$DEVDOC_DIR/archive" ]
}

@test "cleanup.sh does not archive without [archive] (#731)" {
    _seed_transcript
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"archive-transcripts"* ]]
    [[ "$output" != *"transcript archive"* ]]
    [ -z "$(find "$DEVAGENT_TMP" -name last-run)" ]
}

# --- #749: cleanup commits only the paths it owns -----------------------------

@test "#749: cleanup's commit holds only the issue dir (subdirectory fixture)" {
    devdoc_parent_repo_fixture
    printf 'edit
' >> "$DEVDOC_DIR/Issue-2/checklist.md"                     # another issue's dirt
    mkdir -p "$DEVDOC_DIR/Captures/c1"; printf 'draft
' > "$DEVDOC_DIR/Captures/c1/draft.md"   # a fresh capture
    printf 'staged
' >> "$DEVDOC_REPO/proj2/Issue-9/checklist.md"           # another project's STAGED edit
    ( cd "$DEVDOC_REPO" && git add proj2/Issue-9/checklist.md )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run git -C "$DEVDOC_REPO" show --name-only --format= HEAD
    [ -n "$output" ]
    [ -z "$(printf '%s
' "$output" | grep -v '^testproj/Issue-1/')" ]
    run git -C "$DEVDOC_REPO" status --porcelain --untracked-files=all
    [[ "$output" == *" M testproj/Issue-2/checklist.md"* ]]
    [[ "$output" == *"?? testproj/Captures/c1/draft.md"* ]]
    [[ "$output" == *"M  proj2/Issue-9/checklist.md"* ]]
}

@test "#749: cleanup's commit carries WBS.md when it changed, and a hand edit with it" {
    sed -i 's/^- \[ \]\([ ]*\([0-9]*\)\.\)/- [x]\1/' "$DEVDOC_DIR/Issue-1/checklist.md"
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' '
    printf '%s
' "# $TEST_PROJECT WBS" '' '- [ ] Plan {est: 1w}' '  - [~] Working leaf {issue: Issue-1, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    printf '%s
' '- [ ] Hand-added {est: 1d}' >> "$DEVDOC_DIR/WBS.md"      # the operator's own edit
    . "$BATS_TEST_DIRNAME/helpers/wbs-tracker.bash"
    export WBS_STUB_ROOT="$DEVAGENT_TMP"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/backends"
    wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
    printf '1	done
' > "$DEVAGENT_TMP/state-list.github"
    wbs_tracker_install_shims "$DEVAGENT_TMP/shims" "$DEVAGENT_TMP/network.log"
    PATH="$DEVAGENT_TMP/shims:$PATH" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run git -C "$DEVDOC_DIR" show --name-only --format= HEAD
    [[ "$output" == *"WBS.md"* ]]
    run git -C "$DEVDOC_DIR" show HEAD:WBS.md
    [[ "$output" == *"Hand-added"* ]]
    [[ "$output" == *"[x] Working leaf"* ]]
    [ -z "$(git -C "$DEVDOC_DIR" status --porcelain -- WBS.md)" ]
}

@test "#749: cleanup commits a deletion inside the issue dir" {
    printf 'old
' > "$DEVDOC_DIR/Issue-1/old.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "old" )
    rm "$DEVDOC_DIR/Issue-1/old.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run git -C "$DEVDOC_DIR" show --name-status --format= HEAD
    [[ "$output" == *"D	Issue-1/old.md"* ]]
    [ -z "$(git -C "$DEVDOC_DIR" status --porcelain -- Issue-1)" ]
}

@test "#749: devdoc status calls run with GIT_OPTIONAL_LOCKS=0 and leave the index untouched" {
    printf 'notes
' > "$DEVDOC_DIR/Issue-1/notes.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "notes" )
    touch -d '2001-01-01 00:00:00' "$DEVDOC_DIR/Issue-1/notes.md"   # stat-dirty, content unchanged
    w="$(devdoc_git_logging_wrapper "$DEVAGENT_TMP/git.log")"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devdoc_assert_status_rows_readonly "$DEVAGENT_TMP/git.log" "$DEVDOC_DIR"
}

@test "#749: cleanup names a mid-merge devdoc repository" {
    ( cd "$DEVDOC_DIR" && git checkout -q -b side && printf 's
' > side.txt && git add side.txt       && git commit -q -m side && git checkout -q main && git merge -q --no-commit --no-ff side )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"mid-merge"* ]]
    git -C "$DEVDOC_DIR" rev-parse -q --verify MERGE_HEAD
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q 'cleanup_open: NOT closed - devdoc repository mid-merge' "$DEVDOC_DIR/Issue-1/checklist.md"
}

# --- #749: unowned paths are reported, not swept ------------------------------

# _age15 <path>… — every file under each path 15 days old.
_age15() { find "$@" -exec touch -d '15 days ago' {} +; }

@test "#749: unowned paths are counted on one info line" {
    mkdir -p "$DEVDOC_DIR/Issue-2" "$DEVDOC_DIR/Captures/c1"
    printf 'x\n' > "$DEVDOC_DIR/Issue-2/checklist.md"
    printf 'draft\n' > "$DEVDOC_DIR/Captures/c1/draft.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'unowned path(s)')" -eq 1 ]
    [[ "$output" == *"cleanup: 2 unowned path(s) under $DEVDOC_DIR left uncommitted (not Issue-1's): "* ]]
    [[ "$output" == *"Captures/c1/"* ]]
    [[ "$output" == *"Issue-2/"* ]]
    [[ "$output" != *"WARNING:"* ]]
}

@test "#749: an in-flight issue dir 15 days old keeps the line info" {
    mkdir -p "$DEVDOC_DIR/Issue-2"
    printf 'x\n' > "$DEVDOC_DIR/Issue-2/checklist.md"
    _age15 "$DEVDOC_DIR/Issue-2"
    printf '\n[context.Issue-2]\nbranch = "feat/2-x"\n' >> "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"cleanup: 1 unowned path(s)"*"Issue-2/"* ]]
    [[ "$output" != *"WARNING:"* ]]
}

@test "#749: a filed capture 15 days old makes the line a warn (subdirectory fixture)" {
    devdoc_parent_repo_fixture
    mkdir -p "$DEVDOC_DIR/Captures/c-old" "$DEVDOC_DIR/Captures/c-new" "$DEVDOC_DIR/Issue-3"
    printf 'draft\n' > "$DEVDOC_DIR/Captures/c-old/draft.md"
    printf 'issue = 5\n' > "$DEVDOC_DIR/Captures/c-old/filed.toml"
    _age15 "$DEVDOC_DIR/Captures/c-old"
    printf 'draft\n' > "$DEVDOC_DIR/Captures/c-new/draft.md"
    printf 'a\n' > "$DEVDOC_DIR/Issue-3/a.md"
    ( cd "$DEVDOC_REPO" && git add -A testproj/Issue-3 && git commit -q -m i3 && git mv testproj/Issue-3/a.md testproj/Issue-3/b.md )
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    line="$(printf '%s\n' "$output" | grep 'unowned path(s)')"
    [[ "$line" == *"WARNING: cleanup: 3 unowned path(s)"* ]]
    [[ "$line" == *" - older than 7 days and not in flight: Captures/c-old/; commit or remove them by hand"* ]]
    [[ "$line" == *"Captures/c-new/"* ]]
    [[ "$line" == *"Issue-3/"* ]]
    [[ "$line" != *"testproj/"* ]]
    [[ "$line" != *"Captures/,"* ]]
    [[ "$line" != *"Captures/ "* ]]
}

@test "#749: no unowned paths prints no line" {
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"unowned"* ]]
}

@test "#749: a register layer the drain deferred on is not listed" {
    stage_in_project_layer
    printf '%s\n' '- foreign (Issue-3).' >> "$DEVDOC_DIR/templates/potholes.md"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *pending* ]]                                 # the drain did defer
    [[ "$output" != *"unowned"* ]]
}

# --- #749: cleanup holds the repository lock; a failed close is never closed ---

_state_file() { printf '%s\n' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"; }
_seed_context() { printf '\n[context.Issue-1]\nbranch = "feat/1-x"\n' >> "$(_state_file)"; }
_all_rows_done() {
    sed -i 's/^- \[ \]/- [x]/' "$DEVDOC_DIR/Issue-1/checklist.md"
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 ' '
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "rows done" )
}

@test "#749: a lock timeout at hold 2 returns the row to [~], keeps state, and a re-run closes" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _seed_context
    cp "$(_state_file)" "$DEVAGENT_TMP/state.before"
    before="$(git -C "$DEVDOC_DIR" rev-parse HEAD)"
    lp="$(devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2)"
    DEVAGENT_DEVDOC_LOCK_TIMEOUT=1 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"$lp"* ]]
    [[ "$output" == *"pid 4242"* ]]
    [[ "$output" == *"for Issue-2"* ]]
    [[ "$output" == *"cleanup: devdoc lock timeout - the cleanup step is left [~] and the issue's state is kept"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q 'cleanup_open: NOT closed - devdoc lock timeout' "$DEVDOC_DIR/Issue-1/checklist.md"
    cmp "$(_state_file)" "$DEVAGENT_TMP/state.before"
    [ "$(git -C "$DEVDOC_DIR" rev-parse HEAD)" = "$before" ]
    rm -f "$lp/holder" && rmdir "$lp"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    [ "$(git -C "$DEVDOC_DIR" rev-list --count "$before"..HEAD)" -eq 1 ]
    grep -q '^active_issue *= *""' "$(_state_file)"
}

@test "#749: a lock timeout at hold 1 leaves [~] and the promotion pending" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    stage_in_project_layer
    before="$(git -C "$DEVDOC_DIR" rev-parse HEAD)"
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    DEVAGENT_DEVDOC_LOCK_TIMEOUT=1 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q '^status: pending' "$DEVDOC_DIR/Issue-1/potholes-promotion.md"
    [ "$(git -C "$DEVDOC_DIR" rev-parse HEAD)" = "$before" ]
}

@test "#749: an index.lock at commit time leaves [~] and state; a re-run completes" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _seed_context
    g="$DEVAGENT_TMP/gate"; w="$(devdoc_git_gate_wrapper "$g")"; : > "$g/index-lock"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"cleanup: devdoc commit failed - the cleanup step is left [~]"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q '^\[context\.Issue-1\]' "$(_state_file)"
    grep -q '^active_issue *= *"Issue-1"' "$(_state_file)"
    [ ! -e "$(devdoc_lock_test_path "$DEVDOC_DIR")" ]
    rm -f "$DEVDOC_DIR/.git/index.lock"                       # the other writer finished
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    ! grep -q '^\[context\.Issue-1\]' "$(_state_file)" || false
    [ -z "$(git -C "$DEVDOC_DIR" status --porcelain -- Issue-1)" ]
}

@test "#749: a failing pre-commit hook leaves [~] and state; a re-run completes" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _seed_context
    printf '#!/bin/sh\nexit 1\n' > "$DEVDOC_DIR/.git/hooks/pre-commit"; chmod +x "$DEVDOC_DIR/.git/hooks/pre-commit"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q 'cleanup_open: NOT closed - devdoc commit failed' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q '^\[context\.Issue-1\]' "$(_state_file)"
    rm -f "$DEVDOC_DIR/.git/hooks/pre-commit"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    ! grep -q '^\[context\.Issue-1\]' "$(_state_file)" || false
}

@test "#749: a GC failure after the commit leaves [~] and the context" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _seed_context
    g="$DEVAGENT_TMP/gate"; w="$(devdoc_git_gate_wrapper "$g")"; : > "$g/ro-state"
    p="$DEVAGENT_TMP/ro-probe"; mkdir -p "$p"; chmod a-w "$p"
    if ( : > "$p/x" ) 2>/dev/null; then chmod u+w "$p"; skip "a dir stays writable after chmod a-w (root or noacl)"; fi
    chmod u+w "$p"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    chmod u+w "$HOME/.claude/devagent/state"                  # restore before any assertion can fail
    [ "$status" -ne 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
    grep -q 'cleanup_open: NOT closed' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q '^\[context\.Issue-1\]' "$(_state_file)"
    [ ! -e "$(devdoc_lock_test_path "$DEVDOC_DIR")" ]
}

@test "#749: cleanup is the recorded holder at each devdoc commit" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    stage_in_project_layer
    w="$(devdoc_git_logging_wrapper "$DEVAGENT_TMP/git.log")"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run awk -F'\t' '$1 == "commit" { print $6 " " $7 " " $8 }' "$DEVAGENT_TMP/git.log"
    [ "$(printf '%s\n' "$output" | wc -l)" -ge 2 ]                          # the drain's commit and cleanup's
    [ "$(printf '%s\n' "$output" | sort -u | wc -l)" -eq 1 ]                # one holder throughout
    [[ "$output" == [0-9]*" Issue-1 cleanup.sh"* ]]
}

@test "#749: GC runs after the commit" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _seed_context
    g="$DEVAGENT_TMP/gate"; w="$(devdoc_git_gate_wrapper "$g")"; : > "$g/snap-state"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q '^\[context\.Issue-1\]' "$g/state-snap/$TEST_PROJECT.toml"     # still there at commit time
    ! grep -q '^\[context\.Issue-1\]' "$(_state_file)" || false                      # gone at exit
}

@test "#749: the lock is released before the push" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    git init -q --bare "$DEVAGENT_TMP/remote.git"
    git -C "$DEVDOC_DIR" remote add origin "$DEVAGENT_TMP/remote.git"
    w="$(devdoc_git_logging_wrapper "$DEVAGENT_TMP/git.log")"
    DEVAGENT_GIT="$w" run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    run awk -F'\t' '$1 == "push" { print $6 " " $9 }' "$DEVAGENT_TMP/git.log"
    [ "$output" = "- -" ]                                                    # no holder record, no token
    git -C "$DEVAGENT_TMP/remote.git" rev-parse -q --verify refs/heads/main
}

@test "#749: no backend call runs while cleanup holds the lock" {
    unset DEVAGENT_DEVDOC_LOCK_TOKEN
    _all_rows_done
    stage_in_project_layer
    printf '%s\n' "# $TEST_PROJECT WBS" '' '- [ ] Plan {est: 1w}' '  - [~] Working leaf {issue: Issue-1, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    lp="$(devdoc_lock_test_path "$DEVDOC_DIR")"
    mkdir -p "$DEVAGENT_TMP/lockcheck"
    cat > "$DEVAGENT_TMP/lockcheck/github.sh" <<EOF
#!/usr/bin/env bash
if [ -e "$lp" ]; then echo held >> "$DEVAGENT_TMP/lock-seen"; else echo free >> "$DEVAGENT_TMP/lock-seen"; fi
[ "\$1" = state-list ] && { printf '1\tdone\n'; exit 0; }
exit 78
EOF
    chmod +x "$DEVAGENT_TMP/lockcheck/github.sh"
    . "$BATS_TEST_DIRNAME/helpers/wbs-tracker.bash"
    wbs_tracker_install_shims "$DEVAGENT_TMP/shims" "$DEVAGENT_TMP/network.log"
    DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/lockcheck" PATH="$DEVAGENT_TMP/shims:$PATH" \
        run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -s "$DEVAGENT_TMP/lock-seen" ]
    ! grep -q held "$DEVAGENT_TMP/lock-seen" || false
    grep -qxF -- '  - [x] Working leaf {issue: Issue-1, est: 1w, status_src: tracker}' "$DEVDOC_DIR/WBS.md"
}

@test "#749: closing an unpinned issue with no WBS leaf leaves WBS.md unchanged" {
    _all_rows_done
    printf '%s\n' "# $TEST_PROJECT WBS" '' '- [ ] Other {issue: Issue-7, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    cp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/wbs.before"
    DEVAGENT_WBS_OFFLINE=1 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cmp "$DEVDOC_DIR/WBS.md" "$DEVAGENT_TMP/wbs.before"
}

@test "#749: a pinned close still auto-adds the pinned issue as today" {
    mkdir -p "$DEVDOC_DIR/Issue-2"
    sed 's/Issue-1/Issue-2/' "$DEVDOC_DIR/Issue-1/checklist.md" > "$DEVDOC_DIR/Issue-2/checklist.md"
    seed_lessons_learned "$DEVDOC_DIR/Issue-2"
    printf '%s\n' "# $TEST_PROJECT WBS" '' '- [ ] Other {issue: Issue-7, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    DEVAGENT_WBS_OFFLINE=1 DEVAGENT_ACTIVE_ISSUE=Issue-2 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q 'Unassigned' "$DEVDOC_DIR/WBS.md"
    grep -q '{issue: Issue-2' "$DEVDOC_DIR/WBS.md"
}

@test "#749: cleanup warns and completes when the WBS replace fails" {
    _all_rows_done
    printf '%s\n' "# $TEST_PROJECT WBS" '' '- [ ] Plan {est: 1w}' '  - [~] Working leaf {issue: Issue-1, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    DEVAGENT_WBS_OFFLINE=1 DEVAGENT_TEST_WBS_REPLACE_FAILS=99 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"cleanup: wbs reconcile failed (non-fatal) - the WBS leaf for Issue-1 was NOT updated; after the close, re-run /devagent:wbs update $TEST_PROJECT"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
    grep -qxF -- '  - [~] Working leaf {issue: Issue-1, est: 1w}' "$DEVDOC_DIR/WBS.md"
}

@test "#749: a devdoc_dir configured in another letter case still commits (case-insensitive filesystems)" {
    alt="$(dirname "$DEVDOC_DIR")/TESTPROJ"
    [ -d "$alt" ] || skip "case-sensitive filesystem: $alt is not $DEVDOC_DIR"
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.devdoc_dir" "$alt"
    before="$(git -C "$DEVDOC_DIR" rev-parse HEAD)"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"devdoc commit skipped"* ]]
    [[ "$output" != *"unowned"* ]]
    [ "$(git -C "$DEVDOC_DIR" rev-list --count "$before"..HEAD)" -eq 1 ]
    run git -C "$DEVDOC_DIR" show --name-only --format= HEAD
    [[ "$output" == *"Issue-1/checklist.md"* ]]
}

@test "#749: commit_devdoc=false closes with no lock taken" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    DEVAGENT_DEVDOC_LOCK_TIMEOUT=1 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 x cleanup
}

@test "#749 review: an issue dir outside the devdoc repo warns to commit by hand and lists no unowned dir" {
    git -C "$DEVDOC_DIR/Issue-1" init -q
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not inside the git repository holding"*"devdoc commit skipped; commit it by hand"* ]]
    [[ "$output" != *"unowned"* ]] || false
}

@test "#749 red-team: one close's lock waits share one deadline (the reconcile's wait shortens hold 2's)" {
    _all_rows_done
    printf '%s\n' "# $TEST_PROJECT WBS" '' '- [ ] Plan {est: 1w}' '  - [~] Working leaf {issue: Issue-1, est: 1w}' > "$DEVDOC_DIR/WBS.md"
    ( cd "$DEVDOC_DIR" && git add -A && git commit -q -m "seed wbs" )
    devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-2
    DEVAGENT_WBS_OFFLINE=1 DEVAGENT_DEVDOC_LOCK_TIMEOUT=2 run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"gave up after this run's shared lock deadline"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 23 '~' cleanup
}
