#!/usr/bin/env bats
# #660: evidence must come from a FRESH measured tree, and must say which branch it
# measured. run-suite.sh refuses a detached HEAD (DETACHED HEAD). It also refuses a HEAD
# that does not contain origin's tip of its branch after a bounded fetch (BEHIND ORIGIN),
# and it records branch: and upstream:. preship-evidence.sh checks branch: against the
# issue's recorded branch, and reads upstream: as its second provenance rung (#655
# vocabulary). Every origin here is a LOCAL bare repo under $DEVAGENT_TMP (no network,
# no DNS). The one hung fetch waits DEVAGENT_FETCH_TIMEOUT=1 second.
load 'helpers/common'

setup() {
    devagent_test_setup
    cd "$SOURCE_DIR" || return
    mkdir -p tests && echo '# placeholder' > tests/x.bats
    git add -A && git commit -q -m "seed tests"
    ST="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    devagent_state_set "$ST" branch main
    devagent_state_set "$ST" baseline_sha "$(git rev-parse HEAD~1)"   # baseline..HEAD = 1 file
    mkdir -p "$DEVAGENT_TMP/binstub"
    # a green 1/1 bats, leaving a marker so "no suite ran" is observable
    printf '%s\n' '#!/usr/bin/env bash' 'touch "$DEVAGENT_TMP/bats-ran"' 'echo "1..1"' 'echo "ok 1 a"' \
        > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
}
teardown() { devagent_test_teardown; }

_rs()   { PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT" Issue-1; }
_pe()   { run "$DEVAGENT_ROOT/scripts/preship-evidence.sh" "$TEST_PROJECT" Issue-1 "$@"; }
_art()  { ls "$DEVDOC_DIR/Issue-1/analysis/"*-suite-count.txt; }
_arts() { find "$DEVDOC_DIR" -name '*-suite-count.txt' | wc -l; }
# A tag, read from its ONE home: the column-0 assignment in the script (register Issue-585).
_tag()  { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$DEVAGENT_ROOT/scripts/$2"; }
# SOURCE_DIR gets a local bare origin holding its main. MOVER is a second clone that
# pushes to it: a collaborator, or the tree the blessed clone fetches from.
_origin() {
    git -c init.defaultBranch=main init -q --bare "$DEVAGENT_TMP/origin.git"
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/origin.git"
    git -C "$SOURCE_DIR" push -q origin main
    MOVER="$DEVAGENT_TMP/mover"
    git clone -q "$DEVAGENT_TMP/origin.git" "$MOVER"
    git -C "$MOVER" config user.email m@example.com
    git -C "$MOVER" config user.name Mover
}
# One commit on origin's <branch> (default main), pushed from MOVER. Prints the new tip.
_advance() {
    local b="${1:-main}"
    git -C "$MOVER" fetch -q origin
    if git -C "$MOVER" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null; then
        git -C "$MOVER" checkout -q -B "$b" "origin/$b"
    else
        git -C "$MOVER" checkout -q -b "$b"
    fi
    git -C "$MOVER" commit -q --allow-empty -m "origin moves $b"
    git -C "$MOVER" push -q origin "$b"
    git -C "$MOVER" rev-parse HEAD
}

# ---- run-suite: the FRESHNESS refusal ---------------------------------------------

@test "#660 AC1: a tree one commit behind origin refuses BEHIND ORIGIN naming both shas and the branch; nothing runs or is written" {
    # SOURCE_DIR is the CONFIGURED source_dir: the no-exemption shape (the blessed clone is
    # its own config's source_dir, red-team r2).
    local tag head tip
    tag="$(_tag behind_origin run-suite.sh)"
    [ "$tag" = "BEHIND ORIGIN" ]
    _origin
    head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    tip="$(_advance)"
    [ "$head" != "$tip" ]
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$tag"* ]]
    [[ "$output" == *"$head"* ]]
    [[ "$output" == *"$tip"* ]]
    [[ "$output" == *"branch 'main'"* ]]
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts)" -eq 0 ]
}

@test "#660 AC4: BEHIND ORIGIN's remedy, run as printed in a spaced clone that is its own source_dir, clears it" {
    # Register Issue-594/Fork-132: execute the message's own remedy. Register Issue-597:
    # a SPACED path, so a quoting defect in the printed command cannot hide.
    _origin
    local blessed="$DEVAGENT_TMP/blessed clone" tip cmd
    git clone -q "$DEVAGENT_TMP/origin.git" "$blessed"
    devagent_config_set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.source_dir" "$blessed"
    tip="$(_advance)"
    cd "$blessed"
    _rs
    [ "$status" -eq 1 ]
    cmd="$(printf '%s\n' "$output" | sed -n "s/.*re-run: \(git -C '[^']*' merge --ff-only origin\/[^ ]*\).*/\1/p")"
    [ -n "$cmd" ]
    run bash -c "$cmd"
    [ "$status" -eq 0 ]
    _rs
    [ "$status" -eq 0 ]
    grep -q "^upstream: $tip$" "$(_art)"
    grep -q '^branch: main$' "$(_art)"
}

@test "#660 AC1: a detached HEAD refuses DETACHED HEAD naming the sha; nothing runs or is written" {
    local tag head
    tag="$(_tag head_detached run-suite.sh)"
    [ "$tag" = "DETACHED HEAD" ]
    head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    git -C "$SOURCE_DIR" checkout -q --detach
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$tag"* ]]
    [[ "$output" == *"$head"* ]]
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    [ "$(_arts)" -eq 0 ]
}

@test "#660 AC4: the WSL shape - detached, then fetch and checkout of the branch as the refusal prints - proceeds" {
    _origin
    local tip cmd
    tip="$(_advance feat/660-x)"
    git -C "$SOURCE_DIR" checkout -q --detach
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_tag head_detached run-suite.sh)"* ]]
    cmd="$(printf '%s\n' "$output" | sed -n "s/.*re-run: \(git -C '[^']*' checkout\) <branch>.*/\1/p")"
    [ -n "$cmd" ]
    git -C "$SOURCE_DIR" fetch -q origin                     # the message: fetch first if the branch is new here
    run bash -c "$cmd feat/660-x"
    [ "$status" -eq 0 ]
    _rs
    [ "$status" -eq 0 ]
    grep -q '^branch: feat/660-x$' "$(_art)"
    grep -q "^upstream: $tip$" "$(_art)"
}

@test "#660 AC1: a diverged tree (local commit and origin moved) refuses as behind" {
    _origin
    local tip; tip="$(_advance)"
    git -C "$SOURCE_DIR" commit -q --allow-empty -m "local only"
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_tag behind_origin run-suite.sh)"* ]]
    [[ "$output" == *"$tip"* ]]
}

@test "#660: a tree ahead of origin proceeds and records origin's tip, not its own HEAD" {
    _origin
    local tip; tip="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    git -C "$SOURCE_DIR" commit -q --allow-empty -m "local only"
    [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$tip" ]   # discriminating (register Issue-118)
    _rs
    [ "$status" -eq 0 ]
    grep -q "^upstream: $tip$" "$(_art)"
}

@test "#660 AC2: no origin records branch: and upstream: (no-origin) after file_modes:, with no degradation warning" {
    _rs
    [ "$status" -eq 0 ]
    local art; art="$(_art)"
    grep -q '^branch: main$' "$art"
    grep -q '^upstream: (no-origin)$' "$art"
    [ "$(grep -c '^branch:' "$art")" -eq 1 ]
    [ "$(grep -c '^upstream:' "$art")" -eq 1 ]
    # relative order, never an absolute line (register Issue-587)
    [ "$(grep -n '^branch:' "$art" | cut -d: -f1)" -gt "$(grep -n '^file_modes:' "$art" | cut -d: -f1)" ]
    [ "$(grep -n '^upstream:' "$art" | cut -d: -f1)" -gt "$(grep -n '^branch:' "$art" | cut -d: -f1)" ]
    head -1 "$art" | grep -qE '^head: [0-9a-f]+  dirty: (yes|no)$'
    [[ "$output" != *"recording upstream"* ]]               # the single-tree case is not a degradation
}

@test "#660 AC2: an unreachable origin records upstream: (unreachable), warns naming git's exit, and writes the artifact" {
    # At the DEFAULT bound (register lawfirm Issue-7: one test at the real value): a
    # path that does not exist fails fast, so nothing waits.
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/no-such-origin.git"
    _rs
    [ "$status" -eq 0 ]
    grep -q '^upstream: (unreachable)$' "$(_art)"
    [[ "$output" == *"recording upstream: (unreachable)"* ]]
    [[ "$output" == *"git fetch exited"* ]]
}

@test "#660 AC2: a hung fetch is cut off by DEVAGENT_FETCH_TIMEOUT and recorded (unreachable)" {
    _origin
    printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" fetch "*) exec sleep 30 ;; esac' 'exec git "$@"' \
        > "$DEVAGENT_TMP/hang-git"
    chmod +x "$DEVAGENT_TMP/hang-git"
    local t0=$SECONDS
    DEVAGENT_GIT="$DEVAGENT_TMP/hang-git" DEVAGENT_FETCH_TIMEOUT=1 _rs
    [ "$status" -eq 0 ]
    grep -q '^upstream: (unreachable)$' "$(_art)"
    [[ "$output" == *"timed out after 1s"* ]]
    [ $((SECONDS - t0)) -lt 25 ]                            # well inside the shim's 30 s hang
}

@test "#660 AC2: a branch origin lacks records upstream: (unpushed)" {
    _origin
    git -C "$SOURCE_DIR" checkout -q -b fix/660-local
    _rs
    [ "$status" -eq 0 ]
    grep -q '^branch: fix/660-local$' "$(_art)"
    grep -q '^upstream: (unpushed)$' "$(_art)"
}

@test "#660: a bad DEVAGENT_FETCH_TIMEOUT dies naming it, before the freshness check and before any suite runs" {
    git -C "$SOURCE_DIR" checkout -q --detach               # would refuse DETACHED HEAD if the knob were checked later
    DEVAGENT_FETCH_TIMEOUT=abc _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"DEVAGENT_FETCH_TIMEOUT"* ]]
    [[ "$output" != *"$(_tag head_detached run-suite.sh)"* ]]
    [ ! -e "$DEVAGENT_TMP/bats-ran" ]
    DEVAGENT_FETCH_TIMEOUT=0 _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"DEVAGENT_FETCH_TIMEOUT"* ]]
}

@test "#660: the suite child never sees DEVAGENT_FETCH_TIMEOUT" {
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s" "${DEVAGENT_FETCH_TIMEOUT-<UNSET>}" > "$DEVAGENT_TMP/seen-child-timeout"' \
        'echo "1..1"' 'echo "ok 1 a"' > "$DEVAGENT_TMP/binstub/bats"
    chmod +x "$DEVAGENT_TMP/binstub/bats"
    DEVAGENT_FETCH_TIMEOUT=7 _rs
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVAGENT_TMP/seen-child-timeout")" = "<UNSET>" ]
}

@test "#660: DEVAGENT_TREE_GUARD_OVERRIDE does not silence the freshness refusal" {
    # register Issue-597: cross the new policy with the existing flag nearest to it.
    git -C "$SOURCE_DIR" checkout -q --detach
    DEVAGENT_TREE_GUARD_OVERRIDE=1 _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_tag head_detached run-suite.sh)"* ]]
}

@test "#660 ordering: ISSUE UNSTATED and TREE MISMATCH fire before the freshness refusal (pin)" {
    # A pin, green before #660 too: allow-listed for born-red (Validation). The tag is a
    # LITERAL here on purpose: at baseline its home does not exist, and an empty _tag
    # would make every `!=` leg fail, so the pin could not run there.
    git -C "$SOURCE_DIR" worktree add -q -b wt-branch "$DEVAGENT_TMP/wt" HEAD
    git -C "$SOURCE_DIR" checkout -q --detach               # the configured tree would refuse DETACHED HEAD
    PATH="$DEVAGENT_TMP/binstub:$PATH" run "$DEVAGENT_ROOT/scripts/run-suite.sh" "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ISSUE UNSTATED"* ]]
    [[ "$output" != *"DETACHED HEAD"* ]]
    cd "$DEVAGENT_TMP/wt"
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"TREE MISMATCH"* ]]
    [[ "$output" != *"DETACHED HEAD"* ]]
}

@test "#660: branch: is the full ref minus refs/heads/, even when a tag shares the name" {
    git -C "$SOURCE_DIR" checkout -q -b dup
    git -C "$SOURCE_DIR" tag dup
    [ "$(git -C "$SOURCE_DIR" symbolic-ref --short HEAD)" = "heads/dup" ] \
        || skip "this git does not shorten ambiguously; the leg below still runs where it does"
    _rs
    [ "$status" -eq 0 ]                                     # no origin: the single-tree case proceeds
    grep -q '^branch: dup$' "$(_art)"
}
