#!/usr/bin/env bats
# #885: scripts/mergemr.sh — step 20, the merge step. It merges the issue's PR only
# when permissions.merge_mr is exactly true, and only at the head the last passing
# preship recorded (verified_head). Marks its own row by name: [x] merged, [-] ship
# skipped, [?] waiting (all exit 0; next.sh reads the glyph), [!] a stop that writes
# STUCK with `mergemr rule <N>: <text>` and exits 1. Decision order: commands/mergemr.md.
#
# Stub code backend (DEVAGENT_CODE_BACKEND_DIR): mr-view serves $MV_OUT ($MV_OUT_AFTER
# once a merge-mr call succeeded); merge-mr writes its argv to $MERGE_LOG (one
# `[elem]` line per element, then `--`) and exits $MERGE_RC; mr-state/issue-mrs answer
# from files under $STUB_DIR; every call is counted in $STUB_DIR/calls. Stub issue
# backend: state-class from $STUB_DIR/sc.<num>, transition logged to $DEVAGENT_STUB_LOG.
# Fixture checklist: ship [x] 18, mergetoall 19, mergemr 20, updatewbs 21.
load 'helpers/common'

URL=https://github.com/acme/testproj/pull/77

setup() {
    devagent_test_setup
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export CFG="$HOME/.claude/devagent/config.toml"
    export ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    export CL="$ISSUE_DIR/checklist.md"
    export MM="$DEVAGENT_ROOT/scripts/mergemr.sh"
    export STUB_DIR="$DEVAGENT_TMP/stub"
    export MERGE_LOG="$STUB_DIR/merge.log"
    mkdir -p "$STUB_DIR"
    : > "$STUB_DIR/calls"

    # The PR head is a real commit on the issue branch, so remedy tests can run
    # preship-verified-head.sh (pin/record) against it.
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b feat/1-x \
      && echo f1 > f1.txt && git add f1.txt && git commit -q -m f1 )
    export PR_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$STATE" branch "feat/1-x"
    devagent_state_set "$STATE" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse main)"
    devagent_state_set "$STATE" mr_url "$URL"
    devagent_state_set "$STATE" verified_head "$PR_HEAD"
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.merge_mr" true

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
- [x] 18. ship
- [-] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
- [ ] 22. impact
- [ ] 23. lessonslearned
- [ ] 24. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF

    mkdir -p "$DEVAGENT_TMP/fake-code" "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"; v="$1"; shift
printf '%s\n' "$v" >> "$d/calls"
case "$v" in
  mr-view)
    if [ -f "$d/merged" ]; then
      [ -z "${STUB_VIEW_AFTER_SLEEP:-}" ] || exec sleep "$STUB_VIEW_AFTER_SLEEP"
      if [ "${STUB_VIEW_AFTER_RC:-0}" != 0 ]; then echo "stub: re-read failed" >&2; exit "$STUB_VIEW_AFTER_RC"; fi
      cat "${MV_OUT_AFTER:-$MV_OUT}"
    else
      [ -z "${STUB_VIEW_SLEEP:-}" ] || exec sleep "$STUB_VIEW_SLEEP"
      if [ "${STUB_VIEW_RC:-0}" != 0 ]; then echo "gh: noise above" >&2; echo "HTTP 502: bad gateway" >&2; exit "$STUB_VIEW_RC"; fi
      cat "$MV_OUT"
    fi ;;
  merge-mr)
    printf '[%s]\n' "$@" >> "$MERGE_LOG"; printf -- '--\n' >> "$MERGE_LOG"
    [ -z "${STUB_MERGE_SLEEP:-}" ] || exec sleep "$STUB_MERGE_SLEEP"
    if [ "${MERGE_RC:-0}" != 0 ]; then printf '%s\n' "${STUB_MERGE_ERR:-stub: merge failed}" >&2; exit "$MERGE_RC"; fi
    [ "${2:-}" = --disable-auto ] || touch "$d/merged" ;;
  mr-state)
    printf '%s\n' "$1" >> "$d/mr-state.args"
    k="${1##*/}"
    [ -z "${STUB_MRSTATE_SLEEP:-}" ] || exec sleep "$STUB_MRSTATE_SLEEP"
    rc="$(cat "$d/mrstate.$k.rc" 2>/dev/null || echo "${STUB_MRSTATE_RC:-0}")"
    if [ "$rc" != 0 ]; then echo "stub: mr-state failed" >&2; exit "$rc"; fi
    cat "$d/mrstate.$k" 2>/dev/null || printf '%s\n' "${STUB_MRSTATE:-OPEN}" ;;
  issue-mrs)
    printf '%s\n' "$*" >> "$d/issue-mrs.args"
    if [ "${STUB_IM_RC:-0}" != 0 ]; then echo "stub: issue-mrs failed" >&2; exit "$STUB_IM_RC"; fi
    shift
    for n in "$@"; do printf 'issue\t%s\t%s\n' "$n" "$(cat "$d/im.$n" 2>/dev/null || echo none)"; done ;;
  *) exit 2 ;;
esac
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    cp "$DEVAGENT_TMP/fake-code/github.sh" "$DEVAGENT_TMP/fake-code/gitlab.sh"
    export DEVAGENT_CODE_BACKEND_DIR="$DEVAGENT_TMP/fake-code"

    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<'EOF'
#!/usr/bin/env bash
v="$1"; shift
echo "issue/github $v $*" >> "$DEVAGENT_STUB_LOG"
case "$v" in
  state-class)
    f="$STUB_DIR/sc.$2"
    [ -f "$f" ] || { echo "stub: no tracker state for #$2" >&2; exit 1; }
    cat "$f" ;;
esac
exit 0
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"

    _view
}
teardown() { devagent_test_teardown; }

# _view [key=value ...]: write an mr-view reply to $MV_OUT (out=after writes
# $MV_OUT_AFTER instead). checks: space-separated <kind>:<name> (pass|pending|fail),
# empty = no checks. closes/trailers: `;`-separated. commits: "<total> <read>".
_view() {
    local -A f=([state]=open [head]="$PR_HEAD" [checks]="pass:ci" [draft]=false [base]=main
                [mergeable]=MERGEABLE [mergestate]=CLEAN [automerge]=off [queue]=false
                [number]=77 [title]="Add the thing" [mergecommit]=- [commits]="1 1"
                [closes]="" [trailers]="Signed-off-by: Tess <tess@example.com>" [out]=)
    local kv c item path="$DEVAGENT_TMP/view.txt" k
    for kv in "$@"; do f[${kv%%=*}]="${kv#*=}"; done
    if [ "${f[out]}" = after ]; then path="$DEVAGENT_TMP/view-after.txt"; export MV_OUT_AFTER="$path"
    else export MV_OUT="$path"; fi
    {
        printf 'state\t%s\nhead\t%s\n' "${f[state]}" "${f[head]}"
        for c in ${f[checks]}; do
            if [ "${c%%:*}" = fail ]; then printf 'fail\t%s\t-\tFAILURE\n' "${c#*:}"
            else printf '%s\t%s\t-\n' "${c%%:*}" "${c#*:}"; fi
        done
        for k in draft base mergeable mergestate automerge queue number title mergecommit; do
            [ "${f[$k]}" = OMIT ] || printf '%s\t%s\n' "$k" "${f[$k]}"
        done
        IFS=';' read -ra items <<<"${f[closes]}"
        for item in "${items[@]}"; do [ -z "$item" ] || printf 'closes\t%s\t%s\n' "${item% *}" "${item##* }"; done
        IFS=';' read -ra items <<<"${f[trailers]}"
        for item in "${items[@]}"; do [ -z "$item" ] || printf 'trailer\t%s\n' "$item"; done
        printf 'commits\t%s\t%s\n' "${f[commits]% *}" "${f[commits]#* }"
    } > "$path"
}

_run()      { run "$MM" "$TEST_PROJECT" </dev/null; }
_calls()    { grep -cx "$1" "$STUB_DIR/calls" || true; }
# merge calls that would merge (not the --disable-auto form)
_merges()   { [ -f "$MERGE_LOG" ] || { echo 0; return; }; grep -c -- '^\[--match-head-commit\]$' "$MERGE_LOG" || true; }
_reason()   { sed -n 's/^Reason:[[:space:]]*//p' "$ISSUE_DIR/STUCK"; }
_mrlog()    { grep -E '^- [0-9-]+ [0-9:]+  mergemr: ' "$CL" | sed -E 's/^- [0-9-]+ [0-9:]+  mergemr: //'; }
_transitions() { grep -c 'transition' "$DEVAGENT_STUB_LOG" || true; }
_set()      { devagent_config_set "$CFG" "project.$TEST_PROJECT.$1" "$2"; }
_setb()     { devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.$1" "$2"; }

# _wait_is <rule> <reason>: exit 0, row [?], the waiting line printed and logged, no STUCK.
_wait_is() {
    echo "status=$status output=$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting ($1): $2"* ]]
    _mrlog | grep -qxF "waiting ($1): $2"
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

# _stop_is <rule> <text>: exit 1, row [!], STUCK with `mergemr rule <N>: <text>`.
_stop_is() {
    echo "status=$status output=$output" >&2
    [ "$status" -eq 1 ]
    assert_step "$CL" 20 '!' mergemr
    [ -f "$ISSUE_DIR/STUCK" ]
    echo "reason=[$(_reason)]" >&2
    [ "$(_reason)" = "mergemr rule $1: $2" ]
    grep -qE '^Step:[[:space:]]+20 mergemr$' "$ISSUE_DIR/STUCK"
}

# ---- entry and config -------------------------------------------------------

@test "#885 entry: no mergemr row dies, checklist untouched" {
    sed -i '/ 20\. mergemr$/d' "$CL"
    cp "$CL" "$DEVAGENT_TMP/before.md"
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"mergemr: no mergemr row in $CL"* ]]
    cmp "$CL" "$DEVAGENT_TMP/before.md"
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#885 entry: ship not [x] or [-] dies" {
    mark_step "$CL" 18 ' '
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"mergemr: ship is [ ]; run /devagent:ship first"* ]]
    assert_step "$CL" 20 ' ' mergemr
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#885 config: invalid merge_checks dies naming the [project.<p>] key, also with merge_mr false" {
    _set merge_checks always
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        [ "$status" -eq 1 ]
        [[ "$output" == *"merge_checks must be required or if-present (got 'always'); fix [project.testproj] merge_checks"* ]]
        assert_step "$CL" 20 ' ' mergemr
    done
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#885 config: invalid merge_method dies naming the [project.<p>] key, also with merge_mr false" {
    _set merge_method fast-forward
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        [ "$status" -eq 1 ]
        [[ "$output" == *"merge_method must be squash, merge or rebase (got 'fast-forward'); fix [project.testproj] merge_method"* ]]
    done
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#885 config: an invalid [defaults] merge_checks names [defaults]" {
    devagent_config_set "$CFG" defaults.merge_checks maybe
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_checks must be required or if-present (got 'maybe'); fix [defaults] merge_checks"* ]]
}

# ---- rules 1-8 ------------------------------------------------------------------

@test "#885 R1: ship [-] marks [-] and records last_step" {
    mark_step "$CL" 18 -
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 - mergemr
    _mrlog | grep -qxF 'skipped: ship was skipped (no PR)'
    grep -qE '^last_step = "20"' "$STATE"
    grep -qE '^last_step_name = "mergemr"' "$STATE"
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 R2: no mr_url under merge_mr=true is [!] with STUCK" {
    devagent_state_set "$STATE" mr_url ""
    _run
    _stop_is 2 "no PR URL recorded for this issue; merge the PR by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark"
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#885 R2 [?] under merge_mr=false, no STUCK" {
    devagent_state_set "$STATE" mr_url ""
    _setb permissions.merge_mr false
    _run
    _wait_is 2 "no PR URL recorded for this issue; merge the PR by hand, then mark this step [x] with /devagent:checklist-mark"
}

@test "#885 read: PR read failure is [?] with gh's last line, no STUCK" {
    export STUB_VIEW_RC=1
    _run
    _wait_is read "could not read PR $URL: HTTP 502: bad gateway"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 read: PR read timeout is [?], no STUCK" {
    export STUB_VIEW_SLEEP=10 DEVAGENT_MERGEMR_READ_SECS=1
    _run
    _wait_is read "could not read PR $URL: timed out after 1s"
}

@test "#885 read: a reply missing mergestate is [?] (MV_OK=0), no STUCK" {
    _view mergestate=OMIT
    _run
    _wait_is read "could not read PR $URL: unrecognised mr-view output: mergestate missing"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R3: a merged PR marks [x], logs the merge commit, fires on_merge" {
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    _mrlog | grep -qxF "PR $URL merged (merge commit cccccccccccccccccccccccccccccccccccccccc)"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_merge --project testproj"
    grep -qF 'sync: Issue-1 merged → on_merge landed: "Done" on acme/testproj' "$CL"
    grep -qE '^last_step = "20"' "$STATE"
    [ "$(_merges)" -eq 0 ]
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 R4: a PR closed unmerged is [!]" {
    _view state=closed
    _run
    _stop_is 4 "PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"
    [ "$(_merges)" -eq 0 ]
    [ "$(_transitions)" -eq 0 ]
}

@test "#885 R5: a draft PR waits" {
    _view draft=true
    _run
    _wait_is 5 "draft PR"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R6: a PR based on another branch waits" {
    _view base=feat/0-parent
    _run
    _wait_is 6 "stacked on feat/0-parent"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R6: parent merged, base not retargeted, still waits at R6" {
    printf '[Issue-1]\ndepends_on = ["Issue-2"]\n' > "$HOME/.claude/devagent/state/$TEST_PROJECT.depends.toml"
    devagent_state_set "$STATE" "context.Issue-2.mr_url" "https://github.com/acme/testproj/pull/2"
    echo MERGED > "$STUB_DIR/mrstate.2"
    _view base=feat/2-parent
    _run
    _wait_is 6 "stacked on feat/2-parent"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R7: an unsatisfied dependency waits" {
    printf '[Issue-1]\ndepends_on = ["Issue-2"]\n' > "$HOME/.claude/devagent/state/$TEST_PROJECT.depends.toml"
    devagent_state_set "$STATE" "context.Issue-2.mr_url" "https://github.com/acme/testproj/pull/2"
    echo OPEN > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 7 "waiting for Issue-2 (PR open)"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R8: merge_mr=false waits with CI and mergeability, no merge-mr" {
    _setb permissions.merge_mr false
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [[ "$output" == *"CI PASSED: 1 checks on $URL (head ${PR_HEAD:0:7})"* ]]
    [ "$(_merges)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R8: merge_mr unset waits like false" {
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.permissions.merge_mr"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

# ---- merge_mr = false: never merges, never stops ----------------------------------

@test "#885 merge_mr=false: unverified head still [?], no STUCK, no merge-mr" {
    _setb permissions.merge_mr false
    _view head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 merge_mr=false: no verified_head still [?], no STUCK, no merge-mr" {
    _setb permissions.merge_mr false
    devagent_state_set "$STATE" verified_head ""
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 merge_mr=false: PR on another repo still [?], no STUCK, no merge-mr" {
    _setb permissions.merge_mr false
    devagent_state_set "$STATE" mr_url "https://github.com/evil/testproj/pull/77"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 merge_mr=false: DA_YES=1 does not merge" {
    _setb permissions.merge_mr false
    DA_YES=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 merge_mr=false: stdin on a TTY does not merge" {
    command -v script >/dev/null || skip "script(1) not installed"
    _setb permissions.merge_mr false
    run script -qec "'$MM' '$TEST_PROJECT'" /dev/null
    echo "$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    _mrlog | grep -qxF "waiting (8): waiting for merge (green, MERGEABLE/CLEAN)"
    [ ! -e "$ISSUE_DIR/STUCK" ]
    [ ! -e "$MERGE_LOG" ]
}

# ---- rule 7: dependencies --------------------------------------------------------
# merge_mr=false so a satisfied dependency set stops at rule 8, whatever comes later.

_deps() {
    local d out="" sep=""
    for d in "$@"; do out+="$sep\"$d\""; sep=", "; done
    printf '[Issue-1]\ndepends_on = [%s]\n' "$out" > "$HOME/.claude/devagent/state/$TEST_PROJECT.depends.toml"
}
_dep_url() { devagent_state_set "$STATE" "context.$1.mr_url" "https://github.com/acme/testproj/pull/${1##*-}"; }

@test "#885 deps: a recorded PR merged is satisfied; open and closed unmerged each wait" {
    _setb permissions.merge_mr false
    _deps Issue-2; _dep_url Issue-2
    echo MERGED > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    echo OPEN > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 7 "waiting for Issue-2 (PR open)"
    echo CLOSED > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 7 "waiting for Issue-2 (PR closed unmerged)"
    [ "$(_calls issue-mrs)" -eq 0 ]
    devagent_refute_logged "state-class"
}

@test "#885 deps: issue-mrs merged is satisfied, one call for three dependencies" {
    _setb permissions.merge_mr false
    _deps Issue-2 Issue-3 Issue-4
    for n in 2 3 4; do echo merged > "$STUB_DIR/im.$n"; done
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ "$(_calls issue-mrs)" -eq 1 ]
    [ "$(cat "$STUB_DIR/issue-mrs.args")" = "acme/testproj 2 3 4" ]
    [ "$(_calls mr-state)" -eq 0 ]
    devagent_refute_logged "state-class"
}

@test "#885 deps: tracker done is satisfied; not planned and open wait with the reason" {
    _setb permissions.merge_mr false
    _deps Issue-2
    printf 'done\t-\n' > "$STUB_DIR/sc.2"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    devagent_assert_logged "issue/github state-class acme/testproj 2"
    printf 'not_planned\tnot planned\n' > "$STUB_DIR/sc.2"
    _run
    _wait_is 7 "waiting for Issue-2 (closed: not planned)"
    printf 'open\t-\n' > "$STUB_DIR/sc.2"
    _run
    _wait_is 7 "waiting for Issue-2 (open, no PR)"
}

@test "#885 deps: a recorded PR open waits although the tracker issue is closed" {
    _setb permissions.merge_mr false
    _deps Issue-2; _dep_url Issue-2
    echo OPEN > "$STUB_DIR/mrstate.2"
    printf 'done\t-\n' > "$STUB_DIR/sc.2"
    _run
    _wait_is 7 "waiting for Issue-2 (PR open)"
    devagent_refute_logged "state-class"
}

@test "#885 deps: several unsatisfied dependencies are listed in order" {
    _setb permissions.merge_mr false
    _deps Issue-2 Issue-3
    echo draft > "$STUB_DIR/im.2"
    printf 'in_progress\t-\n' > "$STUB_DIR/sc.3"
    _run
    _wait_is 7 "waiting for Issue-2 (PR open); Issue-3 (open, no PR)"
}

@test "#885 deps: an Issue-Fork dependency is read from issue_source_fork" {
    _setb permissions.merge_mr false
    cat >> "$CFG" <<'EOF2'

[project.testproj.issue_source_fork]
backend = "github"
repo    = "me/testproj"
EOF2
    _deps Issue-Fork-5
    echo open > "$STUB_DIR/im.5"
    _run
    _wait_is 7 "waiting for Issue-Fork-5 (PR open)"
    [ "$(cat "$STUB_DIR/issue-mrs.args")" = "me/testproj 5" ]
}

@test "#885 deps: a failed or timed-out dependency read waits, no STUCK" {
    _deps Issue-2; _dep_url Issue-2
    echo 1 > "$STUB_DIR/mrstate.2.rc"
    _run
    _wait_is 7 "could not read Issue-2 PR state: stub: mr-state failed"
    rm "$STUB_DIR/mrstate.2.rc"
    STUB_MRSTATE_SLEEP=10 DEVAGENT_MERGEMR_READ_SECS=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is 7 "could not read Issue-2 PR state: timed out after 1s"
    _deps Issue-3
    STUB_IM_RC=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is 7 "could not read Issue-3 linked PRs: stub: issue-mrs failed"
    _run
    _wait_is 7 "could not read Issue-3 tracker state: stub: no tracker state for #3"
    [ "$(_merges)" -eq 0 ]
}
