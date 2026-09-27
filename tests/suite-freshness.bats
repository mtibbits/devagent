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
    [[ "$output" == *"merge --ff-only origin/main"* ]]      # behind only: the fast-forward remedy
    [[ "$output" != *"DIVERGED"* ]]
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
    local mine cmd; mine="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _rs
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_tag behind_origin run-suite.sh)"* ]]
    [[ "$output" == *"$tip"* ]]
    # Whole-branch review (Important 1): a diverged tree is told so, and its remedy
    # INTEGRATES origin's commits. The fast-forward cannot apply, and neither pushing
    # (rejected) nor dropping this tree's commits is ever the printed advice.
    [[ "$output" == *"DIVERGED"* ]]
    [[ "$output" != *"merge --ff-only"* ]]
    [[ "$output" != *"drop them"* ]]
    cmd="$(printf '%s\n' "$output" | sed -n "s/.*re-run: \(git -C '[^']*' merge --no-edit origin\/[^ ]*\).*/\1/p")"
    [ -n "$cmd" ]
    run bash -c "$cmd"                                       # the remedy, as printed
    [ "$status" -eq 0 ]
    git -C "$SOURCE_DIR" merge-base --is-ancestor "$mine" HEAD   # this tree's commit was kept
    _rs
    [ "$status" -eq 0 ]
    grep -q "^upstream: $tip$" "$(_art)"
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

# ---- preship-evidence: the branch check and the upstream rung ----------------------

# An artifact in SOURCE_DIR's canonical tree (so the tree rung reads `checked` and each
# test fails on its own rung only). $1 = upstream token ("" omits the line),
# $2 = branch ("" omits), $3 = head (default HEAD).
_art660() {
    local up="$1" br="$2" h="${3:-$(git -C "$SOURCE_DIR" rev-parse HEAD)}"
    {   printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\n' "$h" "$(cd "$SOURCE_DIR" && pwd -P)"
        [ -z "$br" ] || printf 'branch: %s\n' "$br"
        [ -z "$up" ] || printf 'upstream: %s\n' "$up"
    } > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
}
_mr660() {   # an mr.md whose Evidence matches a 1/1 bats artifact at $1 (default HEAD)
    { echo '## Summary'; echo x; echo '## Evidence'
      echo "suite: 1/1 bats @ ${1:-$(git -C "$SOURCE_DIR" rev-parse HEAD)}"; echo "files: 1 changed"; } \
      > "$DEVDOC_DIR/Issue-1/mr.md"
}
# The cross-environment shape (#655): the artifact names a tree that does not exist
# here. The path is a VALUE, never created (tests/README.md "Parallel execution").
FOREIGN_TREE="/nonexistent/other-env/devagent"
_foreign660() {   # $1 = upstream token
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\nbranch: main\nupstream: %s\n' \
        "$(git -C "$SOURCE_DIR" rev-parse HEAD)" "$FOREIGN_TREE" "$1" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    _mr660
}
_att_tree() { printf 'head=%s dirty=no path=%s' "$(git -C "$SOURCE_DIR" rev-parse HEAD)" "$FOREIGN_TREE"; }
# What ls-remote PRINTS for <branch> at SOURCE_DIR's origin: the attestation's value
# comes from git's output, never from the artifact (the verifier's rule).
_ls660() { git -C "$SOURCE_DIR" ls-remote origin "refs/heads/$1" | cut -f1; }

@test "#660 AC3: an artifact whose branch: is not the issue's branch fails naming both" {
    _art660 "(no-origin)" feat/561-other
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"produced on branch 'feat/561-other'"* ]]
    [[ "$output" == *"branch is 'main'"* ]]
    [[ "$output" != *"preship-evidence: PASS"* ]]
}

@test "#660 AC3: the branch-mismatch remedy (check out the issue's branch, re-run run-suite) clears it" {
    git -C "$SOURCE_DIR" checkout -q -b feat/561-other
    _rs
    [ "$status" -eq 0 ]
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"produced on branch 'feat/561-other'"* ]]
    git -C "$SOURCE_DIR" checkout -q main
    _rs
    [ "$status" -eq 0 ]
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=no-origin]"* ]]
}

@test "#660 AC3: an artifact with no branch: or upstream: line fails, and re-running run-suite clears it" {
    printf 'head: %s  dirty: no\ntree: %s\nbats: 1/1 notok=0\npytest: (none)\n' \
        "$(git -C "$SOURCE_DIR" rev-parse HEAD)" "$(cd "$SOURCE_DIR" && pwd -P)" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"      # the pre-#660 shape
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no 'branch:' line"* ]]
    [[ "$output" == *"no 'upstream:' line"* ]]
    DEVAGENT_DATE_OVERRIDE=2026-07-10 _rs                                 # the remedy; sorts after 07-09
    [ "$status" -eq 0 ]
    _pe
    [ "$status" -eq 0 ]
}

@test "#660: an issue with no recorded branch fails rather than pass an unchecked branch:" {
    devagent_state_set "$ST" branch ""
    _art660 "(no-origin)" main
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"no branch is recorded"* ]]
    devagent_state_set "$ST" branch main                                  # the repair the message names
    _pe
    [ "$status" -eq 0 ]
}

@test "#660 upstream rung: (no-origin) passes as [upstream=no-origin], a contained tip as [upstream=checked]" {
    _art660 "(no-origin)" main
    _mr660
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=checked] [upstream=no-origin]"* ]]
    _art660 "$(git -C "$SOURCE_DIR" rev-parse HEAD~1)" main
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=checked]"* ]]
}

@test "#660 upstream rung: a recorded tip the shipped head does not contain fails" {
    local side; side="$(git -C "$SOURCE_DIR" commit-tree 'HEAD^{tree}' -m side)"   # a real commit, not an ancestor
    _art660 "$side" main
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"$side"* ]]
    [[ "$output" == *"does not contain"* ]]
}

@test "#660 upstream rung: an unknown or padded token fails" {
    _art660 "(offline)" main
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"'(offline)'"* ]]
    _art660 "(no-origin) " main                                          # trailing blank: unparseable, as #601 rules
    _pe
    [ "$status" -eq 1 ]
}

@test "#660 AC3/AC4: run-suite's real (unreachable) artifact is named UPSTREAM UNATTESTED by preship-evidence" {
    # register Issue-232: feed the producer's REAL artifact through the consumer.
    local tag; tag="$(_tag upstream_unattested preship-evidence.sh)"
    [ "$tag" = "UPSTREAM UNATTESTED" ]
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/no-such-origin.git"
    _rs
    [ "$status" -eq 0 ]
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"$tag"* ]]
    [[ "$output" == *"upstream: (unreachable)"* ]]
    [[ "$output" == *"--attest-upstream"* ]]
    [[ "$output" != *"preship-evidence: PASS"* ]]
}

@test "#660: UPSTREAM UNATTESTED's first remedy (make origin reachable, re-run run-suite) clears it" {
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/origin.git"   # configured before it exists
    _rs
    [ "$status" -eq 0 ]
    grep -q '^upstream: (unreachable)$' "$(_art)"
    _mr660
    _pe
    [ "$status" -eq 1 ]
    git -c init.defaultBranch=main init -q --bare "$DEVAGENT_TMP/origin.git"
    git -C "$SOURCE_DIR" push -q origin main                              # origin answers, and has the branch
    _rs
    [ "$status" -eq 0 ]
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=checked]"* ]]
}

@test "#660 AC3: a cross-environment (unpushed) with only the tree attested fails UPSTREAM UNATTESTED" {
    _foreign660 "(unpushed)"
    _pe --attest-tree "$(_att_tree)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UPSTREAM UNATTESTED"* ]]
    [[ "$output" == *"upstream: (unpushed)"* ]]
    [[ "$output" != *"TREE UNATTESTED"* ]]                               # the tree rung is attested
}

@test "#660 AC3: attesting (unpushed) from ls-remote passes, and the PASS line records both claims" {
    git -c init.defaultBranch=main init -q --bare "$DEVAGENT_TMP/origin.git"   # an origin WITHOUT main
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/origin.git"
    _foreign660 "(unpushed)"
    run git -C "$SOURCE_DIR" ls-remote --exit-code origin refs/heads/main
    [ "$status" -eq 2 ]                                                  # ls-remote's documented "no matching ref"
    local h; h="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$h upstream=(unpushed)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=attested: head=$h"* ]]
    [[ "$output" == *"[upstream=attested: head=$h upstream=(unpushed)"* ]]
}

@test "#660: attesting origin's sha from ls-remote passes when the shipped head contains it" {
    _origin
    _foreign660 "(unreachable)"
    local h tip
    h="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    tip="$(_ls660 main)"
    [ -n "$tip" ]
    _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$h upstream=$tip"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=attested: head=$h upstream=$tip"* ]]
    [[ "$output" == *"containment checked here"* ]]
}

@test "#660: an attested origin sha the shipped head does not contain is refused" {
    _origin
    local moved; moved="$(_advance)"                                    # origin moved past SOURCE_DIR's HEAD
    git -C "$SOURCE_DIR" fetch -q origin                                 # the object exists HERE, so is-ancestor answers 1, not 128
    _foreign660 "(unreachable)"
    [ "$(_ls660 main)" = "$moved" ]
    _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$(git -C "$SOURCE_DIR" rev-parse HEAD) upstream=$moved"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UPSTREAM UNATTESTED"* ]]
    [[ "$output" == *"does not contain"* ]]
}

@test "#660: an upstream sha unknown in the checking tree fails naming the fetch, not a behind tree" {
    # rc 128 from merge-base --is-ancestor is "cannot tell HERE", never "behind" (improve
    # B1; register Issue-458/243). Both arms: the artifact's own sha, then an attested one.
    _origin
    local moved; moved="$(_advance)"                                    # at origin only; SOURCE_DIR never fetches it
    run git -C "$SOURCE_DIR" cat-file -e "$moved^{commit}"
    [ "$status" -ne 0 ]                                                 # discriminating: the object really is absent here
    _art660 "$moved" main
    _mr660
    _pe
    [ "$status" -eq 1 ]
    [[ "$output" == *"fetch origin here"* ]]
    [[ "$output" != *"does not contain"* ]]
    _foreign660 "(unreachable)"
    _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$(git -C "$SOURCE_DIR" rev-parse HEAD) upstream=$moved"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UPSTREAM UNATTESTED"* ]]
    [[ "$output" == *"fetch origin here"* ]]
    [[ "$output" != *"does not contain"* ]]
}

@test "#660: an attestation naming another head, or malformed, is refused" {
    _foreign660 "(unpushed)"
    local other; other="$(git -C "$SOURCE_DIR" rev-parse HEAD~1)"
    _pe --attest-tree "$(_att_tree)" --attest-upstream "head=$other upstream=(unpushed)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names head $other"* ]]
    _pe --attest-tree "$(_att_tree)" --attest-upstream "upstream=(unpushed) head=$other"   # right facts, wrong shape
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed --attest-upstream"* ]]
}

@test "#660: --attest-upstream with no value, an empty value, or given twice is a usage error; unknown options name it" {
    # register Issue-655: one test per parser clause, both spellings.
    _foreign660 "(unpushed)"
    _pe --attest-upstream
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-upstream needs a value"* ]]
    _pe --attest-upstream ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-upstream needs a value"* ]]
    _pe --attest-upstream=
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-upstream needs a value"* ]]
    _pe --attest-upstream "head=x upstream=(unpushed)" --attest-upstream "head=x upstream=(unpushed)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--attest-upstream given more than once"* ]]
    _pe --attest_upstream x
    [ "$status" -eq 1 ]
    [[ "$output" == *"[--attest-upstream '<attestation>']"* ]]
}

@test "#660: an --attest-upstream the rung did not need is ignored with a warning" {
    _art660 "(no-origin)" main
    _mr660
    _pe --attest-upstream "head=$(git -C "$SOURCE_DIR" rev-parse HEAD) upstream=(unpushed)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--attest-upstream ignored"* ]]
    [[ "$output" == *"[upstream=no-origin]"* ]]
}

@test "#660 back-compat: a no-Evidence mr.md beside a pre-660 artifact keeps its single WARN (pin)" {
    # A pin, green before #660 too (allow-listed for born-red): the #149 exit runs before
    # the branch check and the upstream rung.
    printf 'head: %s  dirty: no\nbats: 1/1 notok=0\npytest: (none)\n' "$(git -C "$SOURCE_DIR" rev-parse HEAD)" \
        > "$DEVDOC_DIR/Issue-1/analysis/2026-07-09-suite-count.txt"
    { echo '## Summary'; echo 'no evidence block here'; } > "$DEVDOC_DIR/Issue-1/mr.md"
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"has no '## Evidence' block"* ]]
    [ "$(grep -c WARN <<<"$output")" -eq 1 ]
}

@test "#660 B': a single-tree (unpushed) passes as [upstream=unpushed] with no attestation, and an --attest-upstream there is ignored" {
    # Q1 = B' (intent.md ## Answers). The other half, a cross-environment (unpushed) that
    # still needs the attestation, is the test "a cross-environment (unpushed) with only
    # the tree attested fails UPSTREAM UNATTESTED".
    _origin
    git -C "$SOURCE_DIR" checkout -q -b fix/660-local
    devagent_state_set "$ST" branch fix/660-local
    _rs
    [ "$status" -eq 0 ]
    grep -q '^upstream: (unpushed)$' "$(_art)"
    _mr660
    _pe
    [ "$status" -eq 0 ]
    [[ "$output" == *"[tree=checked] [upstream=unpushed]"* ]]
    [[ "$output" != *"UPSTREAM UNATTESTED"* ]]
    _pe --attest-upstream "head=$(git -C "$SOURCE_DIR" rev-parse HEAD) upstream=(unpushed)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--attest-upstream ignored"* ]]
    [[ "$output" == *"[upstream=unpushed]"* ]]
}

@test "#660: the verifier's --attest-upstream line, filled and run as printed, is the form preship-evidence accepts" {
    # register Issue-461/583: a doc an agent EXECUTES is product behaviour. The verifier
    # carries the matching editor note. One published form, on one line.
    local f="$DEVAGENT_ROOT/agents/preship-verifier.md" line h tip att
    [ "$(grep -c -- "--attest-upstream 'head=" "$f")" -eq 1 ]
    line="$(grep -o -- "--attest-upstream 'head=<SHA printed> upstream=<[^>]*>'" "$f")"
    [ -n "$line" ]
    git -c init.defaultBranch=main init -q --bare "$DEVAGENT_TMP/origin.git"   # origin without the branch
    git -C "$SOURCE_DIR" remote add origin "$DEVAGENT_TMP/origin.git"
    _foreign660 "(unpushed)"
    h="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    tip="$(_ls660 main)"                                                      # prints nothing: unpushed
    line="${line/<SHA printed>/$h}"
    line="${line/upstream=<*>/upstream=${tip:-(unpushed)}}"
    att="${line#--attest-upstream \'}"
    att="${att%\'}"
    _pe --attest-tree "$(_att_tree)" --attest-upstream "$att"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[upstream=attested: head=$h upstream=(unpushed)"* ]]
}

@test "#660: the verifier's UPSTREAM UNATTESTED paragraph has a terminal verdict, a branch source, and a bounded ls-remote" {
    # Whole-branch review (Important 3): step 4 exempts the UNATTESTED tags from FAIL, so a
    # paragraph that ends at the command leaves a failed attested re-run exempt too (a
    # false-green path). The paragraph runs to the next numbered step.
    local f="$DEVAGENT_ROOT/agents/preship-verifier.md" p
    p="$(awk '/[*][*]`UPSTREAM UNATTESTED`[*][*]/{f=1} f && /^[0-9]+[.] [*][*]/{exit} f' "$f" | tr -s '[:space:]' ' ')"
    [ -n "$p" ]
    [[ "$p" == *"that run is the verdict"* ]]
    [[ "$p" == *"any failure in it is a FAIL"* ]]
    [[ "$p" == *"is the artifact's \`branch:\`"* ]]
    [[ "$p" == *"timeout 30"* ]]
}

@test "#660 sweep: every home naming the evidence pair's refusals names the #660 ones" {
    # Homes DERIVED from the claim (register Issue-458/583). Each shipped doc that names
    # run-suite's #659 refusal must name the two #660 refusals. Each doc that names
    # TREE UNATTESTED must name UPSTREAM UNATTESTED and --attest-upstream. The text is
    # whitespace-normalised because prose wraps mid-tag (register Issue-612/465).
    local f t n_run=0 n_up=0 det beh up
    det="$(_tag head_detached run-suite.sh)"
    beh="$(_tag behind_origin run-suite.sh)"
    up="$(_tag upstream_unattested preship-evidence.sh)"
    [ "$det" = "DETACHED HEAD" ]
    [ "$beh" = "BEHIND ORIGIN" ]
    [ "$up" = "UPSTREAM UNATTESTED" ]
    # planted control: the normaliser must join a wrapped tag
    [ "$(printf 'x ISSUE\n   UNSTATED y\n' | tr -s '[:space:]' ' ' | grep -c 'ISSUE UNSTATED')" -eq 1 ]
    for f in "$DEVAGENT_ROOT"/README.md "$DEVAGENT_ROOT"/docs/specs/*.md "$DEVAGENT_ROOT"/docs-site/*.md \
             "$DEVAGENT_ROOT"/skills/*/SKILL.md "$DEVAGENT_ROOT"/skills/*/references/*.md \
             "$DEVAGENT_ROOT"/agents/*.md; do
        t="$(tr -s '[:space:]' ' ' < "$f")"
        if [[ "$t" == *"ISSUE UNSTATED"* ]]; then
            n_run=$((n_run + 1))
            [[ "$t" == *"$det"* ]] || { echo "$f names ISSUE UNSTATED but not $det"; return 1; }
            [[ "$t" == *"$beh"* ]] || { echo "$f names ISSUE UNSTATED but not $beh"; return 1; }
        fi
        if [[ "$t" == *"TREE UNATTESTED"* ]]; then
            n_up=$((n_up + 1))
            [[ "$t" == *"$up"* ]] || { echo "$f names TREE UNATTESTED but not $up"; return 1; }
            [[ "$t" == *"--attest-upstream"* ]] || { echo "$f names TREE UNATTESTED but not --attest-upstream"; return 1; }
        fi
    done
    # Census at 953ac78 (floors, so a new home joins without a re-pin): ISSUE UNSTATED in
    # README, the spec, docs-site/concurrency.md, skills/next/references/concurrency.md;
    # TREE UNATTESTED in README, the spec, agents/preship-verifier.md.
    [ "$n_run" -ge 4 ]
    [ "$n_up" -ge 3 ]
    grep -qF -- '--attest-upstream' "$DEVAGENT_ROOT/CHANGELOG.md"
    grep -qF -- "$det" "$DEVAGENT_ROOT/CHANGELOG.md"
}
