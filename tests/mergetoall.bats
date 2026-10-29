#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b dev/all-prs \
      && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m "feat: x" )
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "feat/1-x"
}
teardown() { devagent_test_teardown; }

# Point config + state at a test-built topology: all_prs_branch in config,
# branch + baseline_sha in state. Shared by the #33 tests below.
_set_baseline_branch() {
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_branch" "$1"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch "$2"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$3"
}

@test "mergetoall.sh squash-merges branch into all_prs_branch" {
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "feat/1-x" ]   # #71: success restores the original branch
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
    # Squash merges land as a single new commit, parent count == 1.
    parents=$( cd "$SOURCE_DIR" && git log -1 --pretty=%P dev/all-prs | wc -w )
    [ "$parents" -eq 1 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "mergetoall.sh refuses a dirty tracked tree and leaves it untouched (#71)" {
    # An uncommitted tracked change would ride onto all_prs and be destroyed by
    # the conflict-recovery reset --hard.
    ( cd "$SOURCE_DIR" && echo "operator wip" >> a.txt )
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]] || [[ "$output" == *"clean"* ]]
    # the operator's change is intact and we're still on feat/1-x
    ( cd "$SOURCE_DIR" && grep -q "operator wip" a.txt )
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
}

@test "mergetoall.sh restores the original branch on success (#71)" {
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )" = "feat/1-x" ]
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
}

@test "mergetoall.sh auto-skips when all_prs_branch is not configured" {
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_branch"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"all_prs_branch not configured"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 '-' mergetoall
    grep -q "auto-skipped: all_prs_branch not configured" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh halts when merge_to_all_prs=false and non-interactive" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.merge_to_all_prs" false
    # Force closed stdin so confirm() sees non-tty regardless of how bats
    # itself was invoked. Without </dev/null this hangs when bats is run
    # from an interactive terminal (read -r -p blocks waiting for input).
    run bash -c "'$DEVAGENT_ROOT/scripts/mergetoall.sh' '$TEST_PROJECT' Issue-1 </dev/null"
    [ "$status" -ne 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
}

@test "mergetoall.sh backward-compat: legacy merge_mr=true still grants permission" {
    # Remove the new name, add the old one.
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.merge_to_all_prs"
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.merge_mr" true
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "mergetoall.sh default does NOT push (local-only)" {
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_refute_logged "git push"
    grep -q "local-only" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh all_prs_auto_push=true pushes after local merge" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_auto_push" true
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push origin dev/all-prs"
    grep -q "pushed to origin/dev/all-prs" "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh all_prs_remote override targets a different remote" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_auto_push" true
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_remote" "fork"
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push fork dev/all-prs"
}

@test "mergetoall.sh tolerates push failure (local merge is load-bearing)" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_auto_push" true
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

# #33: a GENUINE overlap (child's own delta collides with already-integrated work)
# must fail closed — clean tree, restored branch, step 19 unmarked.
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
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
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "mergetoall.sh zero-diff guard rev-lists the issue branch, not source_dir HEAD (#68)" {
    # Same bug as ship.sh: rev-list HEAD ^baseline in source_dir. feat/1-x has a commit
    # but source_dir HEAD is detached at the baseline → HEAD ^baseline is empty → the
    # guard wrongly marks step 19 [-] and the branch is never squash-merged.
    base="$(cd "$SOURCE_DIR" && /usr/bin/git rev-parse feat/1-x~1)"     # feat/1-x's fork point
    ( cd "$SOURCE_DIR" && /usr/bin/git checkout -q "$base" )            # detach HEAD at baseline; HEAD != feat/1-x
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$base"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"zero commits"* ]]                                 # NOT the zero-diff skip
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
}

@test "mergetoall.sh squash subject uses .devagent-title (PR title) when present (#274)" {
    # The branch tip subject is "feat: x"; the PR title differs. The squash subject
    # on dev/all-prs must equal the PR title, not the per-commit tip subject.
    printf '%s' "remove six undiscriminated arch entries (#1)" \
        > "$DEVDOC_DIR/Issue-1/.devagent-title"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    subj="$( cd "$SOURCE_DIR" && git log -1 --pretty=%s dev/all-prs )"
    [ "$subj" = "remove six undiscriminated arch entries (#1)" ]
    [ "$subj" != "feat: x" ]
}

@test "mergetoall.sh squash subject falls back to tip subject when no .devagent-title (#274)" {
    # No .devagent-title (fixture default) → byte-identical pre-#274 behavior:
    # the squash subject equals the branch tip commit subject.
    [ ! -e "$DEVDOC_DIR/Issue-1/.devagent-title" ]
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    subj="$( cd "$SOURCE_DIR" && git log -1 --pretty=%s dev/all-prs )"
    [ "$subj" = "feat: x" ]
}

@test "mergetoall.sh blank .devagent-title falls through to tip subject, not generic (#274)" {
    # A whitespace-only title must NOT short-circuit to the generic message; it
    # falls through to the tip subject (the empty-after-strip edge).
    printf '   \n' > "$DEVDOC_DIR/Issue-1/.devagent-title"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    subj="$( cd "$SOURCE_DIR" && git log -1 --pretty=%s dev/all-prs )"
    [ "$subj" = "feat: x" ]
}

# --- #782: mergetoall requires green CI ---------------------------------------
# The real code/github.sh runs through the gh-stub's `pr view` arm into lib/ci.sh.
# Existing legs record no mr_url, so they take D2 (no read, no gate).
CI_URL=https://github.com/acme/testproj/pull/77

# _ci_serve <fixture>: serve mr-checks-<fixture>.json with headRefOid = $CI_HEAD.
_ci_serve() {
    jq --arg h "$CI_HEAD" '.headRefOid = $h' \
        "$BATS_TEST_DIRNAME/fixtures/code-github/mr-checks-$1.json" > "$DEVAGENT_TMP/mr-checks.json"
    export GH_STUB_PR_CHECKS_FILE="$DEVAGENT_TMP/mr-checks.json"
}

# _ci_mta <fixture>: an MR recorded whose forge head is the local issue branch tip, as
# after a push (mergetoall merges only the head CI checked).
_ci_mta() {
    cp "$BATS_TEST_DIRNAME/fixtures/gh-stub" "$DEVAGENT_STUB_BIN/gh"
    chmod +x "$DEVAGENT_STUB_BIN/gh"
    CI_HEAD="$( cd "$SOURCE_DIR" && git rev-parse feat/1-x )"
    _ci_serve "$1"
    export GH_STUB_PR_CHECKS_LOG="$DEVAGENT_TMP/pr-checks.log"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" mr_url "$CI_URL"
}

_all_prs_tip() { ( cd "$SOURCE_DIR" && git rev-parse dev/all-prs ); }
_state() { python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" "$1"; }

@test "#782 red marks step 19 [!] and STUCK carries the CI FAILED line" {
    _ci_mta red
    local tip; tip="$(_all_prs_tip)"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 '!' mergetoall
    grep -q 'Reason:      CI FAILED: ' "$DEVDOC_DIR/Issue-1/STUCK"
    grep -q '^Step:        19 mergetoall' "$DEVDOC_DIR/Issue-1/STUCK"
    [ "$(_all_prs_tip)" = "$tip" ]
}

@test "#782 pending exits 1, leaves step 19 [ ], writes no STUCK" {
    _ci_mta pending
    local tip; tip="$(_all_prs_tip)"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"CI PENDING: 2 of 2 checks still running on $CI_URL"* ]]
    [[ "$output" == *"mergetoall: not merging until CI is green; nothing was marked"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
    [ ! -e "$DEVDOC_DIR/Issue-1/STUCK" ]
    [ "$(_all_prs_tip)" = "$tip" ]
}

@test "#782 [] within DEVAGENT_CI_GRACE_SECS of ci_seen_at holds; after it proceeds" {
    _ci_mta none
    DEVAGENT_CI_GRACE_SECS=600 run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
    [ "$(_state context.Issue-1.ci_seen_head)" = "$CI_HEAD" ]      # the clock started
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" context.Issue-1.ci_seen_at "$(( $(date +%s) - 1000 ))"
    DEVAGENT_CI_GRACE_SECS=600 run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI NONE: no checks reported on $CI_URL"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "#782 a new head with [] resets ci_seen_at and holds even when the old head's record is old" {
    _ci_mta none
    local f="$HOME/.claude/devagent/state/$TEST_PROJECT.toml" t0
    devagent_state_set "$f" context.Issue-1.ci_seen_head 0000000000000000000000000000000000000001
    devagent_state_set "$f" context.Issue-1.ci_seen_at "$(( $(date +%s) - 1000 ))"
    t0="$(date +%s)"
    DEVAGENT_CI_GRACE_SECS=600 run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [ "$(_state context.Issue-1.ci_seen_head)" = "$CI_HEAD" ]
    [ "$(_state context.Issue-1.ci_seen_at)" -ge "$t0" ]
}

@test "#782 the zero-diff and the unconfigured auto-skips make no CI read" {
    _ci_mta red
    local base
    base="$( cd "$SOURCE_DIR" && git rev-parse feat/1-x )"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$base"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 - mergetoall
    [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' '
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha ""
    devagent_config_unset "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.all_prs_branch"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 - mergetoall
    [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
}

@test "#782 green merges as before and prints CI PASSED" {
    _ci_mta green
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI PASSED: 3 checks on $CI_URL (head ${CI_HEAD:0:7})"* ]]
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "#782 green on the MR head with an unpushed local commit holds, nothing marked" {
    _ci_mta green
    ( cd "$SOURCE_DIR" && echo nit >> a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -qam "nit, not pushed" )
    local tip; tip="$(_all_prs_tip)"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not the MR head CI checked (${CI_HEAD:0:7})"* ]]
    [[ "$output" == *"nothing was marked"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 ' ' mergetoall
    [ ! -e "$DEVDOC_DIR/Issue-1/STUCK" ]
    [ "$(_all_prs_tip)" = "$tip" ]
}

@test "#782 ci_gate = \"off\" merges past a red rollup with no read" {
    _ci_mta red
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.ci_gate" off
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "#782 red → [!] → unstuck → a green rollup on a new head merges" {
    _ci_mta red
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 '!' mergetoall
    run "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$DEVDOC_DIR/Issue-1"
    [ "$status" -eq 0 ]
    # The remedy: a fix pushed to the issue branch is the new head, and it went green.
    ( cd "$SOURCE_DIR" && echo fix >> a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -qam "fix the test" )
    CI_HEAD="$( cd "$SOURCE_DIR" && git rev-parse feat/1-x )"
    _ci_serve green
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CI PASSED: 3 checks on $CI_URL (head ${CI_HEAD:0:7})"* ]]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
}

@test "#782 next --auto from step 19 with green CI prints exactly one CI line, then PHASE BREAK before step 20" {
    _ci_mta green
    local s
    for s in 8 9 10 11 12 13 14 15 16 18; do mark_step "$DEVDOC_DIR/Issue-1/checklist.md" "$s" x; done
    run "$DEVAGENT_ROOT/scripts/next.sh" "$TEST_PROJECT" --auto
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 x mergetoall
    [ "$(grep -c '^CI ' <<<"$output")" -eq 1 ]
    [[ "$output" == *"PHASE BREAK before step 20 (updatewbs)"* ]]
}

@test "#782 next --auto dispatching a stubbed ship: CI line, then PHASE BREAK before step 20 (updatewbs), then Resume" {
    # ship.bats' setup inside this harness: a git PATH shim, an issue-backend stub,
    # mr.md, .devagent-title. Row 19 starts [-] (the standard template's default).
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    echo "kernels: add NEONv8 FMA tier" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    devagent_stub git ""
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    printf '#!/usr/bin/env bash\necho "issue/github $*" >> "%s"\n' "$DEVAGENT_STUB_LOG" > "$DEVAGENT_TMP/fake-issue/github.sh"
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
    cp "$BATS_TEST_DIRNAME/fixtures/gh-stub" "$DEVAGENT_STUB_BIN/gh"
    chmod +x "$DEVAGENT_STUB_BIN/gh"
    export GH_STUB_CREATE_URL="$CI_URL"
    export GH_STUB_PR_CHECKS_FILE="$BATS_TEST_DIRNAME/fixtures/code-github/mr-checks-pending.json"
    local s
    for s in 8 9 10 11 12 13 14 15 16; do mark_step "$DEVDOC_DIR/Issue-1/checklist.md" "$s" x; done
    mark_step "$DEVDOC_DIR/Issue-1/checklist.md" 19 -
    run "$DEVAGENT_ROOT/scripts/next.sh" "$TEST_PROJECT" --auto
    [ "$status" -eq 0 ]
    assert_step "$DEVDOC_DIR/Issue-1/checklist.md" 18 x ship
    local ci pb rs
    ci="$(grep -n '^CI PENDING: ' <<<"$output" | cut -d: -f1)"
    pb="$(grep -n '^PHASE BREAK before step 20 (updatewbs)' <<<"$output" | cut -d: -f1)"
    rs="$(grep -nxF "  Resume: run /clear, then /devagent:next $TEST_PROJECT --auto" <<<"$output" | cut -d: -f1)"
    [ -n "$ci" ] && [ -n "$pb" ] && [ -n "$rs" ]
    [ "$ci" -lt "$pb" ] && [ "$pb" -lt "$rs" ]
}
