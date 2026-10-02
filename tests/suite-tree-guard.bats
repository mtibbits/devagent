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
# #656: the clone clause also refuses when EITHER side's origin, read as a local
# path, is the other side's toplevel. The active.sh contract comment above
# ACTIVE_TREE_MISMATCH_TAG is the one list of the shapes that still fail open and
# of which ones this file pins.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    SRC_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch main   # #660: the issue's branch
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

# #656 helpers. _rs: run-suite on the fixture issue, from the current cwd.
_rs()   { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1; }
_arts() { find "$DEVDOC_DIR" -name '*-suite-count.txt' | wc -l; }
# _refused <fragment>: the last run was a clone-clause refusal whose reason
# contains <fragment> (which names the leg that fired), and it wrote no artifact.
_refused() {
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"TREE MISMATCH"* ]] || return 1
    [[ "$output" == *"separate clone"* ]] || return 1
    [[ "$output" == *"$1"* ]] || return 1
    [ "$(_arts)" -eq 0 ]
}
# _clone <src-spec> <dest>: `git clone` from the current cwd, keeping the NATURAL
# origin git stores. Sets CLONE (absolute) and CLONE_HEAD. Proves the fixture is the
# clone shape (own common dir, so clause 1 cannot decide) and gives the clone its own
# commit, so head: tells the two trees apart (register Issue-118).
_clone() {
    local a b
    git clone -q "$1" "$2" || return 1
    CLONE="$(cd "$2" && pwd)"
    a="$(cd "$CLONE" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    b="$(cd "$SOURCE_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
    [ ! "$a" -ef "$b" ] || return 1
    git -C "$CLONE" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m clone-only || return 1
    CLONE_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
    [ "$CLONE_HEAD" != "$SRC_HEAD" ]
}
# A depth-3 clone whose origin is then set to a LITERAL relative path. `git clone`
# cannot produce one (it stores <abs cwd>/../P), so this is the one #656 fixture
# that uses `remote set-url`, and the value it sets IS a path shape. Only the
# clone's own toplevel resolves the string to SOURCE_DIR: the fixture tells the
# candidate bases apart (register Issue-118).
_lit_clone() {
    _clone "$SOURCE_DIR" "$DEVAGENT_TMP/clones/x/lit" || return 1
    LIT_ORIGIN=../../../src/testproj
    git -C "$CLONE" remote set-url origin "$LIT_ORIGIN" || return 1
    ( cd "$CLONE" && [ "$LIT_ORIGIN" -ef "$SOURCE_DIR" ] ) || return 1          # toplevel base resolves
    ( cd "$CLONE/.git" && [ ! "$LIT_ORIGIN" -ef "$SOURCE_DIR" ] ) || return 1   # GIT_DIR base does not
    ( cd "$SOURCE_DIR" && [ ! "$LIT_ORIGIN" -ef "$SOURCE_DIR" ] )               # nor the other side's
}

@test "#571 AC1: run-suite from an ad-hoc worktree REFUSES and writes no artifact" {
    # the guard must EXIST — a 127 would satisfy the rc assertion vacuously (#572)
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/paths.sh'; . '$DEVAGENT_ROOT/scripts/lib/io.sh'; . '$DEVAGENT_ROOT/scripts/lib/config.sh'; . '$DEVAGENT_ROOT/scripts/lib/state.sh'; . '$DEVAGENT_ROOT/scripts/lib/active.sh'; type active_guard_tree"
    [ "$status" -eq 0 ]
    _mk_wt
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"$WT"* ]] && [[ "$output" == *"$SOURCE_DIR"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]      # NO artifact: assert absence, not a stale-marker presence (#318)
}

@test "#571 AC1: the same run from the configured tree still writes its artifact" {
    # the guard's OTHER branch — a rewrite that fixes one direction must be shown
    # not to have turned fail-closed into fail-open (#558)
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571: DEVAGENT_TREE_GUARD_OVERRIDE=1 restores the old behavior for one call" {
    _mk_wt
    cd "$WT"
    PATH="$DEVAGENT_TMP/binstub:$PATH" DEVAGENT_TREE_GUARD_OVERRIDE=1 \
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt
}

@test "#571 AC1: a separate CLONE of the same project REFUSES (widened clause)" {
    # The second-clone shape: not a linked worktree (own .git), same origin URL.
    # The `remote set-url` below is deliberate: this test pins the URL leg. The
    # natural local-path shape (the origin `git clone` stores) is #656's tests.
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"separate clone"* ]]
    # only the URL leg prints "(origin <url>)": this proves WHICH leg refused (#656)
    [[ "$output" == *"(origin https://example.invalid/acme/testproj)"* ]]
    run bash -c "ls '$DEVDOC_DIR/Issue-1/analysis/'*-suite-count.txt"
    [ "$status" -ne 0 ]
}

@test "#571: a DIFFERENT project's checkout does NOT trip the guard (distinct origins)" {
    # Non-vacuous: both sides have a NON-EMPTY origin and they DIFFER, so the pass is
    # decided by inequality — not by the fail-open empty-URL leg, which the next test
    # covers separately.
    devagent_fixture_projB 1     # separate git init → different --git-common-dir
    # #660: LOCAL paths. run-suite now fetches the measured tree's origin, and a hostname
    # would be a DNS lookup inside the suite (register lectio Issue-10). The clause compares
    # the URL strings, which still differ; the fetch fails fast and records (unreachable).
    # #656: neither origin path resolves (-ef) to the other side's toplevel, so the
    # path legs do not fire. The pass is still decided by inequality.
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/origins/testproj.git"
    git -C "$SRC_B"     remote add origin "$DEVAGENT_TMP/origins/projB.git"
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"TREE MISMATCH"* ]]
}

@test "#571: a remote-less unrelated checkout FAILS OPEN — the guard's stated blind spot" {
    # Pins the DOCUMENTED behavior, so a later change that makes it fail closed
    # reddens here instead of silently breaking every fixture (register Issue-558:
    # the blind spot is part of the contract, so it gets a test like any other clause).
    devagent_fixture_projB 1     # no origin on either side
    cd "$SRC_B"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "#656 leg A: cwd in a clone whose natural origin is the measured tree REFUSES, though the measured tree has no origin" {
    _clone "$SOURCE_DIR" "$DEVAGENT_TMP/clone"
    [ "$(git -C "$CLONE" remote get-url origin)" = "$SOURCE_DIR" ]     # the natural origin
    # the measured tree is remote-less, so the URL leg cannot decide: before #656
    # this run proceeded on the empty-URL fail-open
    run git -C "$SOURCE_DIR" remote get-url origin
    [ "$status" -eq 2 ]
    cd "$CLONE"
    _rs
    _refused "its origin '$SOURCE_DIR' is the tree it would measure"
    # The refusal's override remedy, executed as printed (register Issue-594/597).
    DEVAGENT_TREE_GUARD_OVERRIDE=1 _rs
    [ "$status" -eq 0 ]
    [ "$(_arts)" -eq 1 ]
    grep -q "^head: $SRC_HEAD" "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt   # it measured SOURCE_DIR
}

@test "#656 leg B: cwd in the ORIGINAL while source_dir is its clone REFUSES (the WSL pair), at both evidence doors, and re-running from the clone proceeds" {
    # The real pair: the checkout the session sits in has a forge URL, and the
    # configured source_dir is a clone made FROM it by path.
    git -C "$SOURCE_DIR" remote add origin https://example.invalid/acme/testproj.git
    _clone "$SOURCE_DIR" "$DEVAGENT_TMP/clone"
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.source_dir" "$CLONE"
    # natural, and the two origin strings differ (https vs a path): the URL leg cannot decide
    [ "$(git -C "$CLONE" remote get-url origin)" = "$SOURCE_DIR" ]
    _rs
    _refused "has origin '$SOURCE_DIR', which is this checkout"
    [[ "$output" == *"$CLONE"* ]]
    # The second door: preship-evidence calls the same guard.
    _mk_mr
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" == *"which is this checkout"* ]]
    # The refusal's first remedy, executed as printed: re-run from the measured tree.
    cd "$CLONE"
    _rs
    [ "$status" -eq 0 ]
    art="$(ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt)"
    grep -q "^head: $CLONE_HEAD" "$art"
    grep -q "^tree: $(cd "$CLONE" && pwd -P)$" "$art"
}

@test "#656: a clone made by RELATIVE path (stored as <cwd>/../<P>) REFUSES" {
    mkdir -p "$DEVAGENT_TMP/clones"
    cd "$DEVAGENT_TMP/clones"
    _clone ../src/testproj rel
    o="$(git -C "$CLONE" remote get-url origin)"
    [[ "$o" == *"/clones/../src/testproj" ]]     # what git stores for a relative clone
    [ "$o" != "$SOURCE_DIR" ]                     # string equality could not decide
    cd "$CLONE"
    _rs
    _refused "its origin '$o' is the tree it would measure"
}

@test "#656: a file:// clone REFUSES once the scheme is stripped" {
    _clone "file://$SOURCE_DIR" "$DEVAGENT_TMP/clone-file"
    [ "$(git -C "$CLONE" remote get-url origin)" = "file://$SOURCE_DIR" ]
    [ ! "file://$SOURCE_DIR" -ef "$SOURCE_DIR" ]  # the raw form never resolves: the strip decides
    cd "$CLONE"
    _rs
    _refused "its origin 'file://$SOURCE_DIR' is the tree it would measure"
}

@test "#656 leg B: a literal relative origin resolves against its own repo's toplevel and REFUSES" {
    _lit_clone
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.source_dir" "$CLONE"
    _rs                                           # cwd is SOURCE_DIR (setup)
    _refused "has origin '$LIT_ORIGIN', which is this checkout"
}

@test "#656 leg A: a literal relative origin read from a SUBDIRECTORY of the clone resolves against the clone's toplevel and REFUSES" {
    _lit_clone
    mkdir -p "$CLONE/sub"
    ( cd "$CLONE/sub" && [ ! "$LIT_ORIGIN" -ef "$SOURCE_DIR" ] )   # a process-cwd base would miss
    cd "$CLONE/sub"
    _rs
    _refused "its origin '$LIT_ORIGIN' is the tree it would measure"
}

@test "#656: a clone of a clone FAILS OPEN (a stated surviving shape)" {
    # A pin, green before #656 as well. The origin is a RESOLVING local path that
    # names a third tree, so the pass is decided by -ef inequality, not by a string
    # that resolves nowhere (register Issue-558: pin the no-match branch too).
    _clone "$SOURCE_DIR" "$DEVAGENT_TMP/c1"
    C1="$CLONE"
    _clone "$C1" "$DEVAGENT_TMP/c2"
    [ "$(git -C "$CLONE" remote get-url origin)" -ef "$C1" ]
    run git -C "$SOURCE_DIR" remote get-url origin
    [ "$status" -eq 2 ]
    cd "$CLONE"
    _rs
    [ "$status" -eq 0 ]
    [[ "$output" != *"TREE MISMATCH"* ]]
}

@test "#571: cwd outside any git checkout does NOT trip the guard" {
    mkdir -p "$DEVAGENT_TMP/nowhere"
    cd "$DEVAGENT_TMP/nowhere"
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
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
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
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
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" branch wt-branch   # #660: run-suite measures the worktree, on wt-branch
    BASE="$(git -C "$WT" rev-parse HEAD~1)"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$BASE"
    ( cd "$SOURCE_DIR" && echo a > a.txt && echo b > b.txt && git add -A && git commit -q -m src )
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
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
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\nbranch: main\nupstream: (no-origin)\n' \
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
# mr.md whose Evidence block matches a 1/1 bats artifact at $1 (default SRC_HEAD).
_mk_mr() {
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ ${1:-$SRC_HEAD}"; echo "files: 1 changed"; } \
      > "$DEVDOC_DIR/Issue-1/mr.md"
}
_foreign_fixture() {
    local h="${1:-$SRC_HEAD}"
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\nbranch: main\nupstream: (no-origin)\n' \
        "$h" "$FOREIGN_TREE" > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    _mk_mr "$h"
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
    # An EMPTY value is no value, in either spelling: a caller whose "$ATT" expanded
    # empty is told its input was empty, not sent back to attest (redmr MINOR).
    _pe --attest-tree ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-tree needs a value"* ]]
    _pe --attest-tree=
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-tree needs a value"* ]]
}

@test "#655: an unknown --option is a usage error, not a scope error" {
    # A mistyped flag used to fall through into the [project] [issue] positionals and
    # die on scope or state, or be ignored (redmr MINOR); now it names itself.
    _foreign_fixture
    _pe --attest_tree "head=$SRC_HEAD dirty=no path=$FOREIGN_TREE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option '--attest_tree'"* ]]
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
        run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"2026-07-10-suite-count.txt"* ]]
    [[ "$output" == *"[tree=checked]"* ]]
}

@test "#655: an --attest-tree the rung did not need is ignored with a warning" {
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_state_set "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    _mk_mr
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
    printf 'head: %s  dirty: no\nbats: 1/1 notok=0\npytest: (none)\nbranch: main\nupstream: (no-origin)\n' "$SRC_HEAD" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    _mk_mr
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

@test "#656 sweep: no contract home lists a local-path clone as a fail-open blind spot" {
    # This bats file is not a home: its own regex would match itself.
    local homes=(scripts/lib/active.sh docs/specs/2026-05-19-devagent-plugin-design.md)
    [ "${#homes[@]}" -eq 2 ]
    # Absence half: #656's removal check for the ONE phrasing both homes used, not
    # a standing guard against restating the gap in other words (register Issue-541).
    local old='clone made (FROM|from) a local path'
    local f t n
    # one line, comment leaders dropped: the phrase wrapped across `# ` lines
    _flat() { sed 's/^[[:space:]]*#[[:space:]]*//' "$@" | tr -s '[:space:]' ' '; }
    t="$(printf '%s\n' '#     different transports, or a clone made FROM a local' '#     path (measured' | _flat)"
    [ "$(grep -cE "$old" <<<"$t")" -eq 1 ] || { echo "planted control not matched"; return 1; }
    for f in "${homes[@]}"; do
        t="$(_flat "$DEVAGENT_ROOT/$f")"
        n="$(grep -cE "$old" <<<"$t" || true)"
        [ "$n" -eq 0 ] || { echo "$f still lists a local-path clone as a blind spot"; return 1; }
        # Positive half: each home states the path legs (register Issue-561).
        grep -qF 'both directions' <<<"$t" || { echo "$f does not say both directions"; return 1; }
        grep -qF '#656' <<<"$t" || { echo "$f does not cite #656"; return 1; }
    done
}
# Back-compat pin for artifacts with NO tree: line (every pre-#571 artifact):
# tests/preship-evidence.bats's _artifact helper writes exactly that shape (tree-less,
# but since #660 carrying branch:/upstream:, which every artifact must). Keep it
# tree-less. #655 N11 above pins that shape's PASS-line verdict (tree=unstamped).
