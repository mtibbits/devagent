#!/usr/bin/env bats
# #885 Task 7: scripts/preship-verified-head.sh. `pin` persists the HEAD the
# preship verifier is about to read (preship_pin_head) and prints it; `record`
# reads the pin back after the verifier's turn (no shell variable crosses that
# turn, register Issue-578), refuses when HEAD moved, else writes verified_head
# and clears the pin. A post-ship pass also clears a mergemr stop that a fresh
# preship remedies (rules 10, 11, 14, 15, or a failed post-ship preship) — and
# no other [!]. Real throwaway git repo: the test project's SOURCE_DIR.
load 'helpers/common'

setup() {
    devagent_test_setup
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    export CL="$ISSUE_DIR/checklist.md"
    export PVH="$DEVAGENT_ROOT/scripts/preship-verified-head.sh"
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b feat/1-x \
      && echo f1 > f1.txt && git add f1.txt && git commit -q -m f1 )
    devagent_state_set "$STATE" branch "feat/1-x"
    devagent_state_set "$STATE" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse main)"
}
teardown() { devagent_test_teardown; }

# _key <key>: the issue's state value as the step scripts read it.
_key() {
    bash -c '
        set -euo pipefail
        DEVAGENT_ROOT="$1"
        . "$DEVAGENT_ROOT/scripts/lib/paths.sh"
        . "$DEVAGENT_ROOT/scripts/lib/io.sh"
        . "$DEVAGENT_ROOT/scripts/lib/config.sh"
        . "$DEVAGENT_ROOT/scripts/lib/state.sh"
        . "$DEVAGENT_ROOT/scripts/lib/active.sh"
        state_ctx_get "$2" "$3" Issue-1
    ' _ "$DEVAGENT_ROOT" "$TEST_PROJECT" "$1"
}

_head() { git -C "$SOURCE_DIR" rev-parse HEAD; }
_rows() { grep -E '^- \[.\] +[0-9]+\. ' "$CL"; }

# _postship_checklist: a shipped issue whose mergemr row is pending.
_postship_checklist() {
    cat > "$CL" <<'EOF'
# Issue-1 — Workflow checklist

Template: standard
Created: 2026-05-19 14:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  2. draft
- [x]  9. implement
- [x] 12. commit
- [x] 16. redmr
- [x] 17. preship
- [x] 18. ship
- [x] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
- [ ] 22. impact
- [ ] 23. lessonslearned
- [ ] 24. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF
}

# _stop <step-name> <reason>: the [!] + STUCK pair exactly as checklist-stuck.sh
# writes it (Task 9's mergemr writes `mergemr rule <N>: <text>` this way).
_stop() {
    run "$DEVAGENT_ROOT/scripts/checklist-stuck.sh" --name "$1" "$ISSUE_DIR" "$2"
    [ "$status" -eq 0 ]
    [ -f "$ISSUE_DIR/STUCK" ]
}

# _pin_record: one passing preship's two calls, plain `bash <script> <verb> <project>`.
_pin_record() {
    run bash "$PVH" pin "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    run bash "$PVH" record "$TEST_PROJECT"
    echo "$output" >&2
}

@test "#885 preship-verified-head: pin prints HEAD and persists preship_pin_head" {
    local h; h="$(_head)"
    run bash "$PVH" pin "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [ "$output" = "$h" ]
    [[ "$output" =~ ^[0-9a-f]{40}$ ]]
    [ "$(_key preship_pin_head)" = "$h" ]
    [ -z "$(_key verified_head)" ]
}

@test "#885 preship-verified-head: record writes verified_head, clears the pin, logs it" {
    local h; h="$(_head)"
    _pin_record
    [ "$status" -eq 0 ]
    [[ "$output" == *"preship-verified-head: verified_head $h"* ]]
    [ "$(_key verified_head)" = "$h" ]
    [ -z "$(_key preship_pin_head)" ]
    grep -qE "^- [0-9-]+ [0-9:]+  preship: verified_head $h$" "$CL"
}

@test "#885 preship-verified-head: record without a pin refuses" {
    run bash "$PVH" record "$TEST_PROJECT" Issue-1
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: no pin recorded; run pin first"* ]]
    [ -z "$(_key verified_head)" ]
}

@test "#885 preship-verified-head: a commit between pin and record leaves verified_head unwritten" {
    local h1 h2
    h1="$(_head)"
    run bash "$PVH" pin "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    ( cd "$SOURCE_DIR" && echo f2 > f2.txt && git add f2.txt && git commit -q -m f2 )
    h2="$(_head)"
    run bash "$PVH" record "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: HEAD moved during preship (${h1:0:7} → ${h2:0:7}); nothing recorded"* ]]
    [ -z "$(_key verified_head)" ]
    run grep -q 'preship: verified_head' "$CL"
    [ "$status" -eq 1 ]
}

@test "#885 preship-verified-head: record refuses off-branch" {
    local h; h="$(_head)"
    run bash "$PVH" pin "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    git -C "$SOURCE_DIR" checkout -q main
    run bash "$PVH" record "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: HEAD is on main, not the issue branch feat/1-x"* ]]
    [ -z "$(_key verified_head)" ]
    # pin refuses the same way and writes nothing: the earlier pin (the issue
    # branch's head) survives, main's head is not pinned over it.
    run bash "$PVH" pin "$TEST_PROJECT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: HEAD is on main, not the issue branch feat/1-x"* ]]
    [ "$(_key preship_pin_head)" = "$h" ]
}

# _clears <reason>: a post-ship pass clears the mergemr stop carrying <reason>.
_clears() {
    local reason="$1" h
    _postship_checklist
    _stop mergemr "$reason"
    h="$(_head)"
    _pin_record
    [ "$status" -eq 0 ]
    [ "$(_key verified_head)" = "$h" ]
    assert_step "$CL" 20 ' ' mergemr
    [ ! -f "$ISSUE_DIR/STUCK" ]
    grep -qE "^- [0-9-]+ [0-9:]+  preship: verified_head $h$" "$CL"
    grep -qF "  preship: cleared mergemr stop (${reason:0:60})" "$CL"
    [[ "$output" == *"preship: cleared mergemr stop (${reason:0:60})"* ]]
}

@test "#885 preship-verified-head: post-ship pass clears a rule 11 stop" {
    _clears "mergemr rule 11: PR head abc1234 was not verified; run /devagent:preship on it (auto-merge disabled)"
}

@test "#885 preship-verified-head: post-ship pass clears a rule 10 stop" {
    _clears "mergemr rule 10: no verified head for this PR; run /devagent:preship"
}

@test "#885 preship-verified-head: post-ship pass clears a rule 14 stop" {
    _clears "mergemr rule 14: conflict with main; merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
}

@test "#885 preship-verified-head: post-ship pass clears a rule 15 stop" {
    _clears "mergemr rule 15: ci: red (1 failed: test); fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
}

@test "#885 preship-verified-head: post-ship pass clears a failed post-ship preship stop" {
    _clears "preship: AC 3 not met"
}

@test "#885 preship-verified-head: a rule 9 stop is not cleared" {
    local h
    _postship_checklist
    _stop mergemr "mergemr rule 9: PR is not on acme/testproj; it is on me/testproj. Fix mr_url or code_source, then run /devagent:unstuck"
    cp "$ISSUE_DIR/STUCK" "$DEVAGENT_TMP/STUCK.before"
    h="$(_head)"
    _pin_record
    [ "$status" -eq 0 ]
    [ "$(_key verified_head)" = "$h" ]
    assert_step "$CL" 20 '!' mergemr
    cmp -s "$ISSUE_DIR/STUCK" "$DEVAGENT_TMP/STUCK.before"
    run grep -q 'cleared mergemr stop' "$CL"
    [ "$status" -eq 1 ]
}

@test "#885 preship-verified-head: a mergetoall [!] is not cleared" {
    local h
    _postship_checklist
    mark_step "$CL" 19 ' '
    _stop mergetoall "preship: AC 3 not met"
    cp "$ISSUE_DIR/STUCK" "$DEVAGENT_TMP/STUCK.before"
    h="$(_head)"
    _pin_record
    [ "$status" -eq 0 ]
    [ "$(_key verified_head)" = "$h" ]
    assert_step "$CL" 19 '!' mergetoall
    assert_step "$CL" 20 ' ' mergemr
    cmp -s "$ISSUE_DIR/STUCK" "$DEVAGENT_TMP/STUCK.before"
    run grep -q 'cleared mergemr stop' "$CL"
    [ "$status" -eq 1 ]
}

@test "#885 preship-verified-head: pre-ship record touches no row" {
    _rows > "$DEVAGENT_TMP/rows.before"
    _pin_record
    [ "$status" -eq 0 ]
    _rows | cmp -s - "$DEVAGENT_TMP/rows.before"
    [ ! -f "$ISSUE_DIR/STUCK" ]
}

@test "#885 preship-verified-head: a mergemr stop is not cleared while ship is not [x]" {
    _postship_checklist
    mark_step "$CL" 18 ' '
    _stop mergemr "mergemr rule 11: PR head abc1234 was not verified; run /devagent:preship on it"
    _pin_record
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '!' mergemr
    [ -f "$ISSUE_DIR/STUCK" ]
    run grep -q 'cleared mergemr stop' "$CL"
    [ "$status" -eq 1 ]
}
