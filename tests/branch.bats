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

@test "branch.sh reports an unreachable configured remote distinctly, never wrong-bases [#244]" {
    # origin is CONFIGURED but UNREACHABLE: its URL points at a path that does
    # not exist, so `git fetch origin` fails. default_baseline (origin/main)
    # then can't resolve. This must be diagnosed as the remote being unreachable
    # (offline/transient) — NOT as a pruned/typo'd ref — and must never fall back
    # to HEAD (no wrong-base).
    ( cd "$SOURCE_DIR" && git remote add origin "$DEVAGENT_TMP/does-not-exist.git" )
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "offline base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi "unreachable"                     # the new offline/transient diagnosis
    echo "$output" | grep -qi "refusing to fall back"           # still no HEAD fallback (#72 invariant)
    # The unreachable case must NOT be mislabeled as a pruned/typo'd ref.
    run grep -qi "pruned" <<<"$output"
    [ "$status" -ne 0 ]
    # No branch created: still on main, state branch not a feat/ branch.
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "main"
    run grep -q '^branch *= *"feat/' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

@test "branch.sh diagnoses an AUTH fetch failure distinctly, still no wrong-base (#269)" {
    # origin is configured; the fetch fails with an auth-class stderr. The
    # unreachable-remote diagnostic must name auth (not network), and must still
    # refuse the HEAD fallback (#72 invariant unchanged).
    ( cd "$SOURCE_DIR" && git remote add origin "$DEVAGENT_TMP/does-not-exist.git" )
    cat > "$DEVAGENT_TMP/fakegit-auth" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = fetch ]; then echo "fatal: could not read Username: HTTP 403: Bad credentials" >&2; exit 1; fi
exec git "$@"
EOF
    chmod +x "$DEVAGENT_TMP/fakegit-auth"
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "auth base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    DEVAGENT_GIT="$DEVAGENT_TMP/fakegit-auth" run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    out="$output"                                       # snapshot: `run` below clobbers $output
    echo "$out" | grep -qi "authentication"             # #269 auth-classified
    echo "$out" | grep -qi "refusing to fall back"      # #72 invariant preserved
    run grep -qi "network/availability" <<<"$out"       # NOT the network message
    [ "$status" -ne 0 ]
}

@test "branch.sh diagnoses a NETWORK fetch failure distinctly, still no wrong-base (#269)" {
    ( cd "$SOURCE_DIR" && git remote add origin "$DEVAGENT_TMP/does-not-exist.git" )
    cat > "$DEVAGENT_TMP/fakegit-net" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = fetch ]; then echo "fatal: unable to access: Could not resolve host: github.com" >&2; exit 1; fi
exec git "$@"
EOF
    chmod +x "$DEVAGENT_TMP/fakegit-net"
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "net base" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    DEVAGENT_GIT="$DEVAGENT_TMP/fakegit-net" run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    out="$output"                                       # snapshot: `run` below clobbers $output
    echo "$out" | grep -qi "network/availability"       # #269 network-classified
    echo "$out" | grep -qi "refusing to fall back"
    run grep -qi "authentication" <<<"$out"              # NOT the auth message
    [ "$status" -ne 0 ]
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

@test "branch.sh gives Issue-N and Issue-Fork-N distinct worktree leaves (#332)" {
    python3 - "$HOME/.claude/devagent/config.toml" "$TEST_PROJECT" "$DEVAGENT_TMP/wtroot" <<'PY'
import sys, re
path, proj, root = sys.argv[1:]
text = open(path).read()
insert = f'use_worktree   = true\nworktree_root  = "{root}"\n'
text = re.sub(rf'(\[project\.{re.escape(proj)}\]\n)', r'\1' + insert, text, count=1)
open(path, 'w').write(text)
PY
    # Origin twin and its fork twin share the number 42; distinct titles keep the
    # branch NAMES apart so this isolates the worktree-LEAF collision.
    mkdir -p "$DEVDOC_DIR/Issue-42" "$DEVDOC_DIR/Issue-Fork-42"
    echo feature > "$DEVDOC_DIR/Issue-42/.devagent-type";      echo "origin work" > "$DEVDOC_DIR/Issue-42/.devagent-title"
    echo feature > "$DEVDOC_DIR/Issue-Fork-42/.devagent-type"; echo "fork work"   > "$DEVDOC_DIR/Issue-Fork-42/.devagent-title"
    cp "$DEVDOC_DIR/Issue-1/checklist.md" "$DEVDOC_DIR/Issue-42/checklist.md"
    cp "$DEVDOC_DIR/Issue-1/checklist.md" "$DEVDOC_DIR/Issue-Fork-42/checklist.md"

    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-42
    [ "$status" -eq 0 ]
    # Born-red: the fork twin collapsed onto issue-42 → `git worktree add` "already exists".
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-Fork-42
    [ "$status" -eq 0 ]

    [ -e "$DEVAGENT_TMP/wtroot/issue-42/.git" ]
    [ -e "$DEVAGENT_TMP/wtroot/issue-fork-42/.git" ]
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

@test "twin Issue-N / Issue-Fork-N with the same slug get DISTINCT branches (#422)" {
    # #332 fixed the worktree leaf; the branch NAME still stripped "Fork-" and
    # collapsed the twins → the second `checkout -b`/`worktree add -b` died
    # "already exists". Non-fork stays feat/42-…; fork becomes feat/fork-42-….
    local id
    for id in Issue-42 Issue-Fork-42; do
        mkdir -p "$DEVDOC_DIR/$id"
        cp "$DEVDOC_DIR/Issue-1/checklist.md" "$DEVDOC_DIR/$id/checklist.md"
        echo "feature"         > "$DEVDOC_DIR/$id/.devagent-type"
        echo "same title slug" > "$DEVDOC_DIR/$id/.devagent-title"
    done
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-42
    [ "$status" -eq 0 ]
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-Fork-42
    [ "$status" -eq 0 ]                                  # must NOT die "already exists"
    ( cd "$SOURCE_DIR" && git rev-parse --verify feat/42-same-title-slug >/dev/null )
    ( cd "$SOURCE_DIR" && git rev-parse --verify feat/fork-42-same-title-slug >/dev/null )
}
