#!/usr/bin/env bats
# #571: the evidence pair must measure the checkout the work is in.
# run-suite.sh must refuse (no artifact) when invoked from another checkout of
# the SAME project — a linked git worktree or a separate clone — and stay
# silent from the configured tree, an unrelated project, or no checkout at all.
# WSL-only even per-file: the refusal asserts embed `git rev-parse
# --show-toplevel` output, which Git Bash spells C:/... against /tmp/...
# fixture vars (the active.sh:128-130 spelling asymmetry).
# #655: preship-evidence's tree RUNG. A foreign tree: path (one that does not exist
# in the checking environment) FAILS "TREE UNATTESTED" unless the caller attests
# the tree for this run with --attest-tree; the PASS line ends [tree=<verdict>].
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    SRC_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    mkdir -p "$DEVAGENT_TMP/binstub"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

# An AD-HOC worktree: nothing recorded in state.worktree_path. Lazy — only the
# tests exercising the worktree shape pay the fixture's ~6 process spawns.
_mk_wt() {
    WT="$DEVAGENT_TMP/wt"
    git -C "$SOURCE_DIR" worktree add -q -b wt-branch "$WT" HEAD
    ( cd "$WT" && echo delta > delta.txt && git add -A && git commit -q -m "worktree-only" )
    WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
    [ "$WT_HEAD" != "$SRC_HEAD" ]          # the fixture must actually diverge
}

@test "#571 AC1: run-suite from an ad-hoc worktree REFUSES and writes no artifact" {
    # the guard must EXIST — a 127 would satisfy the rc assertion vacuously (#572)
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/paths.sh'; . '$DEVAGENT_ROOT/scripts/lib/io.sh'; . '$DEVAGENT_ROOT/scripts/lib/config.sh'; . '$DEVAGENT_ROOT/scripts/lib/state.sh'; . '$DEVAGENT_ROOT/scripts/lib/active.sh'; type active_guard_tree"
    [ "$status" -eq 0 ]
    _mk_wt
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"$WT"* ]] && [[ "$output" == *"$SOURCE_DIR"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]      # NO artifact: assert absence, not a stale-marker presence (#318)
}

@test "#571 AC1: the same run from the configured tree still writes its artifact" {
    # the guard's OTHER branch — a rewrite that fixes one direction must be shown
    # not to have turned fail-closed into fail-open (#558)
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571: DEVAGENT_TREE_GUARD_OVERRIDE=1 restores the old behavior for one call" {
    _mk_wt
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" DEVAGENT_TREE_GUARD_OVERRIDE=1 \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571 AC1: a separate CLONE of the same project REFUSES (widened clause)" {
    # The second-clone shape: not a linked worktree (own .git), same origin URL.
    git -C "$SOURCE_DIR" remote add origin https://example.invalid/acme/testproj.git
    CLONE="$DEVAGENT_TMP/clone"
    git clone -q "$SOURCE_DIR" "$CLONE"
    git -C "$CLONE" remote set-url origin https://example.invalid/acme/testproj.git
    # prove the fixture is the CLONE shape, not the worktree shape — otherwise this
    # test would pass on clause 1 and prove nothing about the widening
    A="$(cd "$CLONE" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    B="$(cd "$SOURCE_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    [ ! "$A" -ef "$B" ]
    ( cd "$CLONE" && git -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m clone-only )
    cd "$CLONE"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"separate clone"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]
}

@test "#571: a DIFFERENT project's checkout does NOT trip the guard (distinct origins)" {
    # Non-vacuous: both sides have a NON-EMPTY origin and they DIFFER, so the pass is
    # decided by inequality — not by the fail-open empty-URL leg, which the next test
    # covers separately.
    devagent_fixture_projB 1     # separate git init → different --git-common-dir
    git -C "$SOURCE_DIR" remote add origin https://example.invalid/acme/testproj.git
    git -C "$SRC_B"     remote add origin https://example.invalid/acme/projB.git
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"TREE MISMATCH"* ]]
}

@test "#571: a remote-less unrelated checkout FAILS OPEN — the guard's stated blind spot" {
    # Pins the DOCUMENTED behavior, so a later change that makes it fail closed
    # reddens here instead of silently breaking every fixture (register Issue-558:
    # the blind spot is part of the contract, so it gets a test like any other clause).
    devagent_fixture_projB 1     # no origin on either side
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "#571: cwd outside any git checkout does NOT trip the guard" {
    mkdir -p "$DEVAGENT_TMP/nowhere"
    cd "$DEVAGENT_TMP/nowhere"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

@test "#571 AC2: HEAD moving mid-run REFUSES and writes no artifact" {
    # The symptom depends on ambient state, so the test CONTROLS it (#Fork-149):
    # the bats stub itself moves HEAD in the measured tree before emitting TAP
    # (run-suite has already cd'd there, and the fixture repo has user config).
    printf '%s\n' '#!/usr/bin/env bash' \
        'git commit -q --allow-empty -m "concurrent move"' \
        'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HEAD MOVED"* ]]
    [[ "$output" == *"$SRC_HEAD"* ]]        # names the SHA the stamp was taken at
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]
}

@test "#571 AC4: with a RECORDED worktree, run-suite and preship-evidence agree on one tree" {
    # Fixture is DISCRIMINATING: the worktree and source_dir differ in both HEAD
    # and file count, so a checker still reading source_dir fails on head: AND files:.
    _mk_wt
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" worktree_path "$WT"
    BASE="$(git -C "$WT" rev-parse HEAD~1)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASE"
    ( cd "$SOURCE_DIR" && echo a > a.txt && echo b > b.txt && git add -A && git commit -q -m src )
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q "^head: $WT_HEAD" "$art"          # measured the WORKTREE, not source_dir
    grep -q "^tree: $(cd "$WT" && pwd -P)$" "$art"
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $WT_HEAD"; echo "files: 1 changed"; } \
      > "$DEVDOC_DIR/Issue-1/mr.md"
    run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"[tree=checked]"* ]]      # #655: the rung's verdict ends the PASS line
}

@test "#571 AC4: an artifact stamped with a FOREIGN tree is rejected by preship-evidence" {
    _mk_wt
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\n' \
        "$SRC_HEAD" "$(cd "$WT" && pwd -P)" > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $SRC_HEAD"; echo "files: 1 changed"; } \
      > "$DEVDOC_DIR/Issue-1/mr.md"
    run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"produced from tree"* ]]
}

# #655: the cross-environment shape. The artifact names a tree that does not exist
# in THIS environment (in production, the WSL clone's /home/<user>/... path checked
# from Windows). The path is a VALUE, never created (tests/README.md "Parallel
# execution"). $1 = the head to stamp (default SRC_HEAD). mr.md's suite line always
# matches the artifact, so each test fails only on the rung it is about.
FOREIGN_TREE="/nonexistent/other-env/devagent"
_foreign_fixture() {
    local h="${1:-$SRC_HEAD}"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\n' \
        "$h" "$FOREIGN_TREE" > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $h"; echo "files: 1 changed"; } \
      > "$DEVDOC_DIR/Issue-1/mr.md"
}
# preship-evidence on the fixture issue; extra args (an attestation) pass through.
_pe() { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1 "$@"; }

@test "#655 AC1: a tree path absent here with no attestation FAILS TREE UNATTESTED" {
    # Was #571 AC4's warn-and-proceed pin. That shape is the NORMAL path of every
    # cross-environment preship, so the tree rung silently never ran there. It is
    # now a failure unless the caller attests the tree for this run.
    _foreign_fixture
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
    [[ "$output" == *"$FOREIGN_TREE"* ]]              # names the tree it cannot see
    [[ "$output" == *"--attest-tree"* ]]              # names the per-run remedy
    [[ "$output" != *"preship-evidence: PASS"* ]]
    # The checkout guard's override decides a DIFFERENT question (which checkout a
    # run may act from). It must not silence the rung, or it becomes the standing
    # export #655 rejects (register Issue-597: cross a new policy with every flag).
    run env DEVAGENT_TREE_GUARD_OVERRIDE=1 "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
}

@test "#655 AC2: the sanctioned cross-environment flow PASSES with a matching --attest-tree and the PASS line records it" {
    _foreign_fixture
    _pe --attest-tree "head=$SRC_HEAD dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"preship-evidence: PASS"* ]]
    [[ "$output" == *"[tree=attested: head=$SRC_HEAD dirty=no path=$FOREIGN_TREE"* ]]
    [[ "$output" == *"not checked here"* ]]
    [[ "$output" != *"TREE UNATTESTED"* ]]
    # The --attest-tree=<value> spelling is the same input.
    _pe "--attest-tree=head=$SRC_HEAD dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=attested: head=$SRC_HEAD"* ]]
    # This attestation was built from the fixture, not observed. The script cannot
    # tell the difference (the header's stated blind spot); this test is also that
    # blind spot's demonstration (register Issue-583: run the LIMITS sentence).
}

@test "#655: an attestation naming a different head is refused, naming both SHAs" {
    _foreign_fixture
    other="$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    _pe --attest-tree "head=$other dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
    [[ "$output" == *"$other"* ]]
    [[ "$output" == *"$SRC_HEAD"* ]]
}

@test "#655: an attestation reporting dirty=yes is refused" {
    _foreign_fixture
    _pe --attest-tree "head=$SRC_HEAD dirty=yes path=$FOREIGN_TREE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
    [[ "$output" == *"dirty=yes"* ]]
}

@test "#655: an attestation naming a different path is refused, naming both paths" {
    _foreign_fixture
    _pe --attest-tree "head=$SRC_HEAD dirty=no path=/nonexistent/another-clone"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
    [[ "$output" == *"/nonexistent/another-clone"* ]]
    [[ "$output" == *"$FOREIGN_TREE"* ]]
}

@test "#655: a malformed attestation is refused" {
    _foreign_fixture
    # the right facts in the wrong shape: one accepted form, everything else fails
    _pe --attest-tree "path=$FOREIGN_TREE head=$SRC_HEAD dirty=no"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed --attest-tree"* ]]
}

@test "#655: --attest-tree with no value, or given twice, is a usage error" {
    _foreign_fixture
    _pe --attest-tree
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-tree needs a value"* ]]
    _pe --attest-tree "head=$SRC_HEAD dirty=no path=$FOREIGN_TREE" \
        --attest-tree "head=$SRC_HEAD dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"given more than once"* ]]
}

@test "#655: a matching attestation does not rescue a stale artifact head" {
    # An attestation vouches for the CHECKOUT, never for the counts: the head:
    # comparison still runs on the attested arm. This passes before #655 as well:
    # it is a pin, not a born-red test.
    old="$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    _foreign_fixture "$old"
    _pe --attest-tree "head=$old dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"artifact head ($old) != current HEAD ($SRC_HEAD)"* ]]
    [[ "$output" != *"TREE UNATTESTED"* ]]   # the attestation matched ITS artifact
}

@test "#655: re-running run-suite in this environment clears TREE UNATTESTED" {
    # The refusal's first remedy, executed as printed (register Issue-594): measure
    # the tree being shipped, from here. The new artifact is dated later, so it is
    # the one the checker reads. The second remedy (attest) is executed by AC2.
    _foreign_fixture
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE UNATTESTED"* ]]
    DEVAGENT_DATE_OVERRIDE=2026-07-10 PATH="$DEVAGENT_TMP/binstub:$PATH" \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"2026-07-10-suite-count.txt"* ]]
    [[ "$output" == *"[tree=checked]"* ]]
}

@test "#655: an --attest-tree the rung did not need is ignored with a warning" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $SRC_HEAD"; echo "files: 1 changed"; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _pe --attest-tree "head=$SRC_HEAD dirty=no path=/nonexistent/unused"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--attest-tree ignored"* ]]
    [[ "$output" == *"[tree=checked]"* ]]
}

@test "#655 back-compat: an artifact with no tree line passes as tree=unstamped" {
    # Every pre-#571 artifact (the #149 absent-means-no-gate rule).
    # tests/preship-evidence.bats pins that such artifacts still PASS; this pins
    # the verdict they now print.
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    printf 'head: %s  dirty: no\nbats: 1/1 notok=0\npytest: (none)\n' "$SRC_HEAD" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ $SRC_HEAD"; echo "files: 1 changed"; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=unstamped]"* ]]
}

@test "#655 back-compat: a no-Evidence mr.md beside a foreign-tree artifact keeps its single WARN" {
    # The #149 exit runs BEFORE the tree rung, so a legacy issue with no Evidence
    # block stays shippable exactly as before. This passes before #655 as well: a
    # pin (the "still warns there" negative, register Issue-582).
    _foreign_fixture
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"has no '## Evidence' block"* ]]
    [[ "$output" != *"TREE UNATTESTED"* ]]
    [ "$(grep -c WARN <<<"$output")" -eq 1 ]
}

@test "#655 sweep: every contract home names --attest-tree and none states warn-and-proceed" {
    # The homes come from Task 1's census, not from the issue's list (register
    # Issue-458/583: the subject list grows with the claim). CHANGELOG.md is
    # presence-only: its released [1.0.0] #571 entry is a historical record under
    # a dated heading (register Issue-541), so the absence leg skips it.
    local homes=(scripts/preship-evidence.sh agents/preship-verifier.md
                 docs/specs/2026-05-19-devagent-plugin-design.md README.md)
    [ "${#homes[@]}" -eq 4 ]
    # The retired contract, in the spellings its homes actually used. The text is
    # whitespace-normalised because the verifier's copy wraps mid-phrase (register
    # Issue-612/465).
    local old='falls? back to the head|head:?-comparison fallback|proceeding on the head: comparison alone'
    local c f n
    for c in 'warns and falls back to the head comparison' \
             'loud WARN, # head:-comparison fallback' \
             'warn loudly and fall back to the head: checks' \
             'loud warn + head-comparison fallback' \
             'proceeding on the head: comparison alone'; do
        [ "$(printf '%s\n' "$c" | grep -cE "$old")" -eq 1 ] \
            || { echo "planted control not matched: $c"; return 1; }
    done
    for f in "${homes[@]}"; do
        grep -qF -- '--attest-tree' "$DEVAGENT_ROOT/$f" || { echo "no --attest-tree in $f"; return 1; }
        n="$(tr -s '[:space:]' ' ' < "$DEVAGENT_ROOT/$f" | grep -cE "$old" || true)"
        [ "$n" -eq 0 ] || { echo "$f still states the warn-and-proceed contract"; return 1; }
    done
    grep -qF -- '--attest-tree' "$DEVAGENT_ROOT/CHANGELOG.md" || { echo "no CHANGELOG entry"; return 1; }
    # The verifier must name the tag the script emits, taken from the script
    # itself (register Issue-286/598: a checker must be TOLD the gate's contract).
    local tag
    tag="$(sed -n 's/^tree_unattested="\(.*\)"$/\1/p' "$DEVAGENT_ROOT/scripts/preship-evidence.sh")"
    [ "$tag" = "TREE UNATTESTED" ]
    grep -qF -- "$tag" "$DEVAGENT_ROOT/agents/preship-verifier.md" || { echo "verifier does not name $tag"; return 1; }
}
# Back-compat pin for artifacts with NO tree: line (every pre-#571 artifact):
# tests/preship-evidence.bats's _artifact helper writes exactly that shape and its
# tests stay green untouched — do not "modernize" that helper to add tree:.
# #655 N11 above pins that shape's PASS-line verdict (tree=unstamped).
