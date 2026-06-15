#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "branch.sh creates feat/<num>-<slug> for a feature issue" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "make widgets faster" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "feat/1-make-widgets-faster"
    grep -q '^branch *= *"feat/1-make-widgets-faster"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '\[x\]  6. branch' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'branch: created feat/1-make-widgets-faster' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "branch.sh cuts from a local-branch .devagent-baseline (dev/all-prs shape) [#162]" {
    # Reproduce the Issue-Fork-135 scenario: a file that exists ONLY on an
    # integration branch. The override must cut the branch from there, not main.
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b dev/all-prs \
      && touch HARNESS && git add HARNESS && git commit -q -m "harness on integration branch" \
      && git checkout -q main )
    local base_sha; base_sha="$( cd "$SOURCE_DIR" && git rev-parse dev/all-prs )"
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "stacked feature" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    echo "dev/all-prs" > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # New branch tip == integration-branch tip (cut from the override, not main).
    [ "$( cd "$SOURCE_DIR" && git rev-parse HEAD )" = "$base_sha" ]
    # The integration-only file is present on the new branch.
    [ -f "$SOURCE_DIR/HARNESS" ]
    grep -q "^baseline_sha *= *\"$base_sha\"" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "branch.sh cuts from a remote-ref .devagent-baseline (remote/branch shape) [#162]" {
    local remote="$DEVAGENT_TMP/remote.git"
    git init -q --bare "$remote"
    ( cd "$SOURCE_DIR" \
      && git remote add intremote "$remote" \
      && git checkout -q -b intbranch \
      && touch RFILE && git add RFILE && git commit -q -m "remote int" \
      && git push -q intremote intbranch \
      && git checkout -q main \
      && git branch -q -D intbranch )
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "remote base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    echo "intremote/intbranch" > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # The remote-only file is present → branch was cut from the fetched remote ref.
    [ -f "$SOURCE_DIR/RFILE" ]
}

@test "branch.sh dies on an unresolvable .devagent-baseline — no HEAD fallback [#162]" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "bad base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    echo "no/such/ref" > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "does not resolve"
    # No branch was created; still on main, state branch not a feat/ branch.
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "main"
    # Non-vacuous negative assertion: a bare `! grep` is exempt from bats set -e
    # and would silently pass (SC2314). Capture with run, then assert the status.
    run grep -q '^branch *= *"feat/' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

@test "branch.sh rejects a .devagent-baseline with shell metacharacters [#162]" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "meta base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    printf 'main; rm -rf /\n' > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "invalid baseline"
}

@test "branch.sh rejects an empty/whitespace .devagent-baseline [#162]" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "empty base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    printf '   \n' > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "empty"
}

@test "branch.sh creates a git worktree when use_worktree=true" {
    # Insert use_worktree + worktree_root into the [project.testproj] block.
    python3 - "$HOME/.claude/devagent/config.toml" "$TEST_PROJECT" "$DEVAGENT_TMP/wtroot" <<'PY'
import sys, re
path, proj, root = sys.argv[1:]
text = open(path).read()
insert = f'use_worktree   = true\nworktree_root  = "{root}"\n'
text = re.sub(rf'(\[project\.{re.escape(proj)}\]\n)', r'\1' + insert, text, count=1)
open(path, 'w').write(text)
PY

    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "wt test" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -d "$DEVAGENT_TMP/wtroot/issue-1/.git" ] || [ -f "$DEVAGENT_TMP/wtroot/issue-1/.git" ]
    grep -q "worktree_path *= *\"$DEVAGENT_TMP/wtroot/issue-1\"" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "branch.sh warns loudly when the default baseline falls back to HEAD (missing remote) [#72]" {
    # Fixture default_baseline is origin/main with no 'origin' remote → the
    # default path genuinely can't resolve and falls back to HEAD. That must be LOUD.
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "warn me" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]                                          # offline-fixture behavior preserved
    echo "$output" | grep -qi "falling back to HEAD"            # the #72 loud warning
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "feat/1-warn-me"
}

@test "branch.sh refuses HEAD fallback when the remote exists but the ref is missing [#72]" {
    # origin now EXISTS (empty bare → no 'main' ref): an unresolvable origin/main
    # is a pruned/typo'd ref, NOT a missing remote — must die, never stack on HEAD.
    local remote="$DEVAGENT_TMP/origin.git"
    git init -q --bare "$remote"
    ( cd "$SOURCE_DIR" && git remote add origin "$remote" )
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "ref gone" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "refusing to fall back"
    # No branch created: still on main, state branch not a feat/ branch.
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "main"
    run grep -q '^branch *= *"feat/' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}
