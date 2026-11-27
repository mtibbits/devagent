#!/usr/bin/env bats
# #1055: devdoc_commit_dir (scripts/lib/devdoc-repo.sh) — the best-effort commit
# of ONE devDoc folder that filing and ship use: the folder alone, under the
# #749 lock, as devagent with no sign-off; every refusal is one warning whose
# remedy depends on the reason, and never a failure of the step.
load 'helpers/common'
load 'helpers/devdoc-repo'
bats_require_minimum_version 1.5.0

setup() {
    devagent_test_setup
    unset DEVAGENT_DEVDOC_LOCK_TOKEN DEVAGENT_DEVDOC_LOCK_DEADLINE
    export DEVAGENT_DEVDOC_LOCK_TIMEOUT=1
    devdoc_parent_repo_fixture
    F="$DEVDOC_DIR/Captures/s1"
    mkdir -p "$F"
    printf '# s1\n' > "$F/draft.md"
    # another writer's STAGED edit, which the commit must leave in the index
    printf 'edited\n' >> "$DEVDOC_REPO/proj2/Issue-9/checklist.md"
    git -C "$DEVDOC_REPO" add proj2/Issue-9/checklist.md
    LP="$(devdoc_lock_test_path "$DEVDOC_DIR")"
    SUBJ="devdoc: file s1 as acme/testproj#7"
}
teardown() { devagent_test_teardown; }

# _dcd <args…> — call devdoc_commit_dir the way production does (never bare
# under errexit). The type probe exits 127 first, so no row passes vacuously
# while the function is missing.
_dcd() {
    run --separate-stderr bash -c '
        set -euo pipefail
        L="$1/scripts/lib"; shift
        . "$L/paths.sh"; . "$L/io.sh"; . "$L/config.sh"; . "$L/devdoc-repo.sh"
        type devdoc_commit_dir >/dev/null 2>&1 || exit 127
        devdoc_commit_dir "$@" || rc=$?
        exit "${rc:-0}"' _ "$DEVAGENT_ROOT" "$@"
}

_count() { git -C "$1" rev-list --count HEAD; }
_names() { git -C "$DEVDOC_REPO" show --name-only --format= HEAD; }

# _all_under <prefix> — every path the HEAD commit lists starts with <prefix>,
# and it lists at least one.
_all_under() {
    local n=0 p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        [[ "$p" == "$1"* ]] || { echo "outside $1: $p" >&2; return 1; }
    done < <(_names)
    [ "$n" -ge 1 ]
}

# _mid_merge — leave the devDoc repository mid-merge (MERGE_HEAD present) with
# a merge that does not touch the folder.
_mid_merge() {
    ( cd "$DEVDOC_REPO" && git reset -q && git checkout -q -b side \
      && printf 'side\n' > proj2/side.md && git add proj2/side.md && git commit -q -m side \
      && git checkout -q main && git merge -q --no-ff --no-commit side \
      && git add proj2/Issue-9/checklist.md )
    git -C "$DEVDOC_REPO" rev-parse -q --verify MERGE_HEAD >/dev/null
}

@test "devdoc_commit_dir: commits the folder alone as devagent with no sign-off" {
    before="$(_count "$DEVDOC_REPO")"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(_count "$DEVDOC_REPO")" -eq $((before + 1)) ]
    _all_under testproj/Captures/s1/
    [ "$(git -C "$DEVDOC_REPO" log -1 --format=%s)" = "$SUBJ" ]
    [ "$(git -C "$DEVDOC_REPO" log -1 --format='%an <%ae>')" = "devagent <devagent@local>" ]
    [[ "$(git -C "$DEVDOC_REPO" log -1 --format=%B)" != *Signed-off-by* ]]
    [ "$(git -C "$DEVDOC_REPO" status --porcelain -- proj2/Issue-9/checklist.md)" = "M  proj2/Issue-9/checklist.md" ]
    [ ! -e "$LP" ]
}

@test "devdoc_commit_dir: a clean folder makes no commit and prints nothing" {
    git -C "$DEVDOC_REPO" add testproj/Captures/s1
    git -C "$DEVDOC_REPO" commit -q -m pre -- testproj/Captures/s1
    before="$(_count "$DEVDOC_REPO")"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
}

@test "devdoc_commit_dir: devDoc outside git returns 0 and takes no lock" {
    d="$DEVAGENT_TMP/plain"; mkdir -p "$d/Captures/s1"
    [ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]   # really outside git
    printf '# s1\n' > "$d/Captures/s1/draft.md"
    hp="$(devdoc_lock_stub_holder "$d" Issue-5)"
    cp "$hp/holder" "$DEVAGENT_TMP/holder.before"
    _dcd "$d" "$d/Captures/s1" - "$SUBJ"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    cmp "$hp/holder" "$DEVAGENT_TMP/holder.before"
}

@test "devdoc_commit_dir: an unreadable .git entry warns, never reads as outside git" {
    b="$DEVAGENT_TMP/broken"; mkdir -p "$b/testproj/Captures/s1"
    printf 'gitdir: /nonexistent\n' > "$b/.git"
    printf '# s1\n' > "$b/testproj/Captures/s1/draft.md"
    _dcd "$b/testproj" "$b/testproj/Captures/s1" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"WARNING: devdoc commit of $b/testproj/Captures/s1 skipped - cannot determine the devdoc repository: a .git entry exists but git rev-parse failed; commit it from the devDoc repository by hand"* ]]
    [ "$(printf '%s\n' "$stderr" | grep -c WARNING)" -eq 1 ]
    [[ "$stderr" != *"git -C"* ]]   # an unresolvable repo prints no git command
}

@test "devdoc_commit_dir: a folder in a nested repository warns and commits in neither" {
    git -C "$F" -c init.defaultBranch=main init -q
    before="$(_count "$DEVDOC_REPO")"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"devdoc commit of $F skipped - not inside the git repository holding $DEVDOC_DIR; commit it from the devDoc repository by hand"* ]]
    [[ "$stderr" != *"git -C"* ]]
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
    run ! git -C "$F" rev-parse -q --verify HEAD
}

@test "devdoc_commit_dir: a mid-merge devDoc warns, keeps MERGE_HEAD and releases the lock" {
    _mid_merge
    before="$(_count "$DEVDOC_REPO")"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"devdoc commit of $F skipped - devdoc repository mid-merge"* ]]
    git -C "$DEVDOC_REPO" rev-parse -q --verify MERGE_HEAD >/dev/null
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
    [ ! -e "$LP" ]
}

@test "devdoc_commit_dir: a failing git status warns and does not commit" {
    before="$(_count "$DEVDOC_REPO")"
    printf 'garbage\n' > "$DEVDOC_REPO/.git/index"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"devdoc commit of $F skipped - git status failed; commit it by hand: git -C"* ]]
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
    [ ! -e "$LP" ]
}

@test "devdoc_commit_dir: a held index.lock warns git add failed and leaves the lock file" {
    before="$(_count "$DEVDOC_REPO")"
    touch "$DEVDOC_REPO/.git/index.lock"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"devdoc commit of $F skipped - git add failed; commit it by hand: git -C"* ]]
    [ -e "$DEVDOC_REPO/.git/index.lock" ]
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
    [ ! -e "$LP" ]
}

@test "devdoc_commit_dir: a detached devDoc HEAD warns and does not commit (#1055)" {
    git -C "$DEVDOC_REPO" checkout -q --detach
    before="$(_count "$DEVDOC_REPO")"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"devdoc commit of $F skipped - devdoc repository HEAD is detached; check out a branch, then: git -C"* ]]
    [ "$(_count "$DEVDOC_REPO")" -eq "$before" ]
    [ ! -e "$LP" ]
}

@test "devdoc_commit_dir: the mid-merge remedy works once the merge is aborted" {
    _mid_merge
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"; finish or abort the merge, then: "* ]]
    cmd="${stderr#*finish or abort the merge, then: }"
    git -C "$DEVDOC_REPO" merge --abort
    git -C "$DEVDOC_REPO" add proj2/Issue-9/checklist.md   # abort resets the index
    bash -c "$cmd"
    _all_under testproj/Captures/s1/
    [ "$(git -C "$DEVDOC_REPO" log -1 --format=%s)" = "$SUBJ" ]
}

@test "devdoc_commit_dir: with the bound unset the run deadline caps the wait (10 s default pinned in source)" {
    unset DEVAGENT_DEVDOC_LOCK_TIMEOUT
    hp="$(devdoc_lock_stub_holder "$DEVDOC_DIR" Issue-5)"
    DEVAGENT_DEVDOC_LOCK_DEADLINE="$(date +%s)"   # the deadline caps the default: no wait
    export DEVAGENT_DEVDOC_LOCK_DEADLINE
    t0="$(date +%s)"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    t1="$(date +%s)"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"devdoc commit of $F skipped - devdoc lock timeout; commit it by hand: git -C"* ]]
    [ $((t1 - t0)) -lt 5 ]
    [ -e "$hp/holder" ]
    # the unset default itself: no 10 s sleep in the suite, so pin the source
    grep -qF 'DEVAGENT_DEVDOC_LOCK_TIMEOUT="${DEVAGENT_DEVDOC_LOCK_TIMEOUT:-10}"' "$DEVAGENT_ROOT/scripts/lib/devdoc-repo.sh"
}

@test "devdoc_commit_dir: the printed hand command commits the folder alone" {
    SUBJ="devdoc: it's s1"
    touch "$DEVDOC_REPO/.git/index.lock"
    _dcd "$DEVDOC_DIR" "$F" - "$SUBJ"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"commit it by hand: "* ]]
    cmd="${stderr#*commit it by hand: }"
    rm -f "$DEVDOC_REPO/.git/index.lock"
    bash -c "$cmd"
    _all_under testproj/Captures/s1/
    [ "$(git -C "$DEVDOC_REPO" log -1 --format=%s)" = "$SUBJ" ]
    [ "$(git -C "$DEVDOC_REPO" status --porcelain -- proj2/Issue-9/checklist.md)" = "M  proj2/Issue-9/checklist.md" ]
}
