#!/usr/bin/env bats
# tests/local-callers.bats — #1016: the local code backend's callers. The
# backend's own verbs are tests/backend-local.bats (run by backend-contract.bats);
# this file holds what the callers do with it, over the real scripts/code/local.sh:
# comments, mergemr, ship, and the trust entry check.
#
# _local_project makes the fixture project local: code_source.backend = "local"
# with no upstream or fork, default_baseline = "main", no source_remote, and a
# mergemr row. The issue backend is a logging stub (DEVAGENT_ISSUE_BACKEND_DIR).
# PATH shims for git and gh exec the real tool, except that a git push or fetch,
# or any gh call, writes a line to $REMOTE_MARKER and exits 97.
bats_require_minimum_version 1.5.0
load 'helpers/common'

setup() {
    devagent_test_setup
    export CFG="$HOME/.claude/devagent/config.toml"
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    export CL="$ISSUE_DIR/checklist.md"
    export LOCAL="$DEVAGENT_ROOT/scripts/code/local.sh"
    export REMOTE_MARKER="$DEVAGENT_TMP/remote-called"
    _local_project
}

teardown() { devagent_test_teardown; }

_local_project() {
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.backend" local
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.upstream"
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.fork"
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.source_remote"
    devagent_config_set "$CFG" "project.$TEST_PROJECT.default_baseline" main

    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<'EOF'
#!/usr/bin/env bash
echo "issue/github $*" >> "$DEVAGENT_STUB_LOG"
exit 0
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"

    local real_git; real_git="$(command -v git)"
    cat > "$DEVAGENT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
# The subcommand is the first argument that is not an option or an option's value.
skip=0
for a in "\$@"; do
    if [ "\$skip" = 1 ]; then skip=0; continue; fi
    case "\$a" in
        -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
        -*) ;;
        push|fetch) echo "git \$*" >> "$REMOTE_MARKER"; exit 97 ;;
        *) break ;;
    esac
done
exec "$real_git" "\$@"
EOF
    cat > "$DEVAGENT_STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$REMOTE_MARKER"
exit 97
EOF
    chmod +x "$DEVAGENT_STUB_BIN/git" "$DEVAGENT_STUB_BIN/gh"

    cat > "$CL" <<'EOF'
# Issue-1 — Workflow checklist

Template: standard
Created: 2026-05-19 14:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [x]  5. improve
- [x]  6. prune
- [x]  7. tighten
- [x]  8. branch
- [x]  9. implement
- [x] 10. quality
- [x] 11. document
- [x] 12. commit
- [x] 13. analyze
- [x] 14. draftmr
- [x] 15. review
- [x] 16. redmr
- [x] 17. preship
- [ ] 18. ship
- [-] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
- [ ] 22. impact
- [ ] 23. lessonslearned
- [ ] 24. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF
}

# _issue_branch: an issue branch feat/1-x one commit ahead of main, checked out
# on main again (HEAD differs from the branch).
_issue_branch() {
    git -C "$SOURCE_DIR" checkout -q -b feat/1-x
    echo f1 > "$SOURCE_DIR/f1.txt"
    git -C "$SOURCE_DIR" add f1.txt
    git -C "$SOURCE_DIR" commit -q -m f1
    git -C "$SOURCE_DIR" checkout -q main
    _set_branch feat/1-x
    devagent_state_set "$STATE" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse main)"
}

# _set_branch <name>: the state's branch as branch.sh writes it: the issue's
# [context.Issue-1] table (which ship reads first) and the top-level mirror.
_set_branch() {
    devagent_state_set "$STATE" context.Issue-1.branch "$1"
    devagent_state_set "$STATE" branch "$1"
}

# _shipped_by_hand: a record made by local.sh create-mr, its reference as mr_url,
# and the ship row [x].
_shipped_by_hand() {
    _issue_branch
    REF="$("$LOCAL" create-mr "$SOURCE_DIR" "Issue 1" /dev/null feat/1-x main)"
    devagent_state_set "$STATE" mr_url "$REF"
    mark_step "$CL" 18 x
}

_no_remote_calls() {
    [ ! -e "$REMOTE_MARKER" ] || { echo "remote reached: $(cat "$REMOTE_MARKER")" >&2; return 1; }
}

_row() { grep -E "^- \[.\] +$1\. " "$CL" | sed -E 's/^- \[(.)\].*/\1/'; }

@test "comments (local): writes ## Comments (0) (AC 7)" {
    _shipped_by_hand
    run bash "$DEVAGENT_ROOT/scripts/comments.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(cat "$ISSUE_DIR/revisions/r1/comments.md")" = "## Comments (0)" ]
    grep -qE '^- [0-9-]+ [0-9:]+  comments: fetched 0 comments$' "$CL"
    _no_remote_calls
}

@test "mergemr (local): waits with today's message, then marks [x] after a hand merge --no-ff (AC 11)" {
    _shipped_by_hand
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.merge_mr" true
    run "$DEVAGENT_ROOT/scripts/mergemr.sh" "$TEST_PROJECT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"mergemr: waiting (8): waiting for merge (merge step supports github only)"* ]]
    [ "$(_row 20)" = "?" ]
    [[ $'\n'"$output" != *$'\n'"CI "* ]]
    git -C "$SOURCE_DIR" merge -q --no-ff -m "merge feat/1-x" feat/1-x
    run "$DEVAGENT_ROOT/scripts/mergemr.sh" "$TEST_PROJECT" </dev/null
    [ "$status" -eq 0 ]
    [ "$(_row 20)" = "x" ]
    grep -qF "mergemr: PR $REF merged (merge commit -)" "$CL"
    [[ $'\n'"$output" != *$'\n'"CI "* ]]
    _no_remote_calls
}

# --- ship (Task 7) -------------------------------------------------------------

# _ship_ready: the issue branch, mr.md and the title; ship row [ ], preship [x].
_ship_ready() {
    _issue_branch
    echo "MR body" > "$ISSUE_DIR/mr.md"
    echo "Issue 1 title" > "$ISSUE_DIR/.devagent-title"
}

# _cdir: git's own common-dir line for the source repo.
_cdir() { git -C "$SOURCE_DIR" rev-parse --path-format=absolute --git-common-dir | tr -d '\r'; }

# _want_ref <branch>: the reference D-ref builds, by an independent encoder.
_want_ref() {
    python3 -X utf8 -c 'import sys,urllib.parse as u; q=lambda s: u.quote(s, safe="~"); print("local:" + q(sys.argv[1]) + "#" + q(sys.argv[2]))' "$(_cdir)" "$1"
}

_rec_of() {
    printf '%s/devagent/local-mr/%s' "$(_cdir)" \
        "$(python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="~"))' "$1")"
}

_snap() { git -C "$SOURCE_DIR" status --porcelain=v2 --branch; git -C "$SOURCE_DIR" for-each-ref; }

# _mr_url: the state's mr_url (top-level and [context] copies, which agree).
_mr_url() { sed -n 's/^mr_url *= *"\(.*\)"$/\1/p' "$STATE" | sort -u; }

# _ship: run ship from the devdoc folder with no terminal and no DA_YES.
_ship() {
    ( cd "$DEVDOC_DIR" && unset DA_YES && "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1 </dev/null ) > "$DEVAGENT_TMP/ship.out" 2>&1
}
_ship_run() { run _ship; output="$(cat "$DEVAGENT_TMP/ship.out")"; }

# _assert_local_ship: AC 1's result, for <branch> (default feat/1-x).
_assert_local_ship() {
    local b="${1:-feat/1-x}"
    [ "$status" -eq 0 ] || { echo "status $status: $output" >&2; return 1; }
    [[ "$output" != *"Proceed with"* ]]
    [[ "$output" != *"push_mr denied"* ]]
    _no_remote_calls
    [ "$(_mr_url)" = "$(_want_ref "$b")" ]
    grep -qxF "state: open" "$(_rec_of "$b")"
    [[ "$output" == *"  push to:    not applicable (local)"* ]]
    [[ "$output" == *"  MR repo:    $SOURCE_DIR"* ]]
    [ "$(_row 18)" = x ]
}

@test "ship (local, push_mr=false): from the devdoc folder, no prompt, no push, fetch or gh (AC 1)" {
    _ship_ready
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.push_mr" false
    local before; before="$(_snap)"
    _ship_run
    _assert_local_ship
    [ "$(_snap)" = "$before" ]
}

@test "ship (local, push_mr=true): the same result (AC 2)" {
    _ship_ready
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.push_mr" true
    local before; before="$(_snap)"
    _ship_run
    _assert_local_ship
    [ "$(_snap)" = "$before" ]
}

@test "ship (local): leftover upstream, fork, fork_first and fork_only are ignored" {
    _ship_ready
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.upstream" acme/testproj
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.fork" me/testproj
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.fork_first" true
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.fork_only" true
    _ship_run
    _assert_local_ship
}

@test "ship (local): on_ship fires as today" {
    _ship_ready
    _ship_run
    _assert_local_ship
    [ "$(grep -c 'transition .* on_ship' "$DEVAGENT_STUB_LOG")" -eq 1 ]
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.transition_issue" false
    : > "$DEVAGENT_STUB_LOG"
    devagent_state_set "$STATE" mr_url ""
    mark_step "$CL" 18 " "
    _ship_run
    [ "$status" -eq 0 ]
    [ "$(grep -c 'on_ship' "$DEVAGENT_STUB_LOG" || true)" -eq 0 ]
}

@test "ship (local): ship_as_draft prints the draft line and the record is open" {
    _ship_ready
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.ship_as_draft" true
    _ship_run
    _assert_local_ship
    [[ "$output" == *"draft: not applicable (local code backend)"* ]]
}

# _stack_child: a parent branch feat/0-p one commit ahead of main, and the issue
# branch feat/1-x stacked on it (baseline_sha = the parent's tip).
_stack_child() {
    git -C "$SOURCE_DIR" checkout -q -b feat/0-p main
    echo p > "$SOURCE_DIR/p.txt"; git -C "$SOURCE_DIR" add p.txt; git -C "$SOURCE_DIR" commit -q -m p
    git -C "$SOURCE_DIR" checkout -q -b feat/1-x
    echo c > "$SOURCE_DIR/c.txt"; git -C "$SOURCE_DIR" add c.txt; git -C "$SOURCE_DIR" commit -q -m c
    git -C "$SOURCE_DIR" checkout -q main
    _set_branch feat/1-x
    devagent_state_set "$STATE" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse feat/0-p)"
    echo "MR body" > "$ISSUE_DIR/mr.md"
    echo "Issue 1 title" > "$ISSUE_DIR/.devagent-title"
}

@test "ship (local): a stacked child bases on its parent branch (AC 6)" {
    _stack_child
    "$LOCAL" create-mr "$SOURCE_DIR" parent /dev/null feat/0-p main >/dev/null
    _ship_run
    _assert_local_ship
    grep -qxF "base: feat/0-p" "$(_rec_of feat/1-x)"
}

@test "ship (local): a parent whose record is merged sends the child to the default base (AC 6)" {
    _stack_child
    "$LOCAL" create-mr "$SOURCE_DIR" parent /dev/null feat/0-p main >/dev/null
    sed -i 's/^state: open$/state: merged/' "$(_rec_of feat/0-p)"
    run git -C "$SOURCE_DIR" merge-base --is-ancestor feat/0-p main
    [ "$status" -eq 1 ]
    _ship_run
    _assert_local_ship
    grep -qxF "base: main" "$(_rec_of feat/1-x)"
    [[ "$output" == *"stacked parent 'feat/0-p' has an already-merged PR"* ]]
}

@test "ship (local): a second ship after a hand merge fails with the new-branch message" {
    _ship_ready
    _ship_run
    _assert_local_ship
    local url rec; url="$(_mr_url)"; rec="$(_rec_of feat/1-x)"
    cp "$rec" "$DEVAGENT_TMP/rec.copy"
    git -C "$SOURCE_DIR" merge -q --no-ff -m m feat/1-x
    mark_step "$CL" 18 " "
    _ship_run
    [ "$status" -ne 0 ]
    [[ "$output" == *"a merged or closed local MR exists for this branch; ship from a new branch"* ]]
    [ "$(_mr_url)" = "$url" ]
    cmp "$rec" "$DEVAGENT_TMP/rec.copy"
    # The way out, as §9.2 and skills/ship/SKILL.md write it: a new branch, set as
    # `branch` under the issue's [context.<issue>] table (and the top-level
    # mirror) by hand, then ship again.
    git -C "$SOURCE_DIR" branch feat/1-x-2 feat/1-x
    git -C "$SOURCE_DIR" checkout -q feat/1-x-2
    echo more > "$SOURCE_DIR/more.txt"; git -C "$SOURCE_DIR" add more.txt; git -C "$SOURCE_DIR" commit -q -m more
    git -C "$SOURCE_DIR" checkout -q main
    _set_branch feat/1-x-2
    _ship_run
    _assert_local_ship feat/1-x-2
}

@test "ship (Local, a custom Local.sh): the push_mr gate is asked" {
    _ship_ready
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.backend" Local
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.upstream" acme/testproj
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.push_mr" false
    mkdir -p "$DEVAGENT_TMP/code"
    printf '#!/usr/bin/env bash\necho "Local.sh $*" >> "%s"\n[ "$1" = create-mr ] && echo custom:1\nexit 0\n' "$DEVAGENT_STUB_LOG" > "$DEVAGENT_TMP/code/Local.sh"
    chmod +x "$DEVAGENT_TMP/code/Local.sh"
    export DEVAGENT_CODE_BACKEND_DIR="$DEVAGENT_TMP/code"
    _ship_run
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission_gate: push_mr denied"* ]]
    [[ "$output" == *"  push to:    origin"* ]]
    [ "$(grep -c 'Local.sh create-mr' "$DEVAGENT_STUB_LOG" || true)" -eq 0 ]
}

# --- trust (Task 10) -------------------------------------------------------------

# _policy <scope>: a host trust policy at the user level whose one scope is <scope>.
_policy() {
    mkdir -p "$HOME/.config/devagent/trust"
    printf '%s\n' "scopes = [\"$1\"]" 'worker_identities = ["github:1001"]' \
        'quarantine = "devagent:quarantine"' > "$HOME/.config/devagent/trust/policy.toml"
}

# _entry_check <project>: trust_entry_check as an entry point calls it.
_entry_check() {
    bash -c 'set -euo pipefail
        for l in paths io config state transition trust; do . "$1/scripts/lib/$l.sh"; done
        trust_entry_check ship "$2"' _ "$DEVAGENT_ROOT" "$1"
}

@test "trust (local, in scope): next, ship and mergemr exit 9 with the local message and write no record (AC 9)" {
    _ship_ready
    _policy "github:github.com/acme/testproj"
    local ep n=0
    for ep in next.sh ship.sh mergemr.sh; do
        run --separate-stderr "$DEVAGENT_ROOT/scripts/$ep" "$TEST_PROJECT" </dev/null
        [ "$status" -eq 9 ] || { echo "$ep: $status $stderr" >&2; false; }
        [[ "$stderr" == *"local code backend is not supported under a trust policy"* ]]
        n=$((n + 1))
    done
    [ "$n" -eq 3 ]
    [ ! -e "$(_cdir)/devagent" ]
    _no_remote_calls
}

@test "trust (local, out of scope): the same policy does not refuse" {
    _policy "github:github.com/acme/testproj"
    devagent_config_set "$CFG" "project.$TEST_PROJECT.issue_source.repo" other/repo
    run --separate-stderr _entry_check "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "trust (no code_source.backend, in scope): no local-backend refusal" {
    _policy "github:github.com/acme/testproj"
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.backend"
    run --separate-stderr _entry_check "$TEST_PROJECT"
    [[ "$stderr" != *"local code backend"* ]]
}
