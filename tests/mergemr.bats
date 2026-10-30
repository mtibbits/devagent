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
    PR_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"; export PR_HEAD
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
                [closes]="" [trailers]="Signed-off-by: Tess <tess@example.com>" [out]="")
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
    echo draft > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 7 "waiting for Issue-2 (PR open)"
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

# A tracker with no state-class (jira, gitlab, custom answer `usage`, exit 2; 78 is
# "not implemented"): the stub mirrors that. Path (2) is GitHub-only, so no issue-mrs.
_jira_tracker() {
    _set issue_source.backend jira
    _set issue_source.repo ACME
    cat > "$DEVAGENT_TMP/fake-issue/jira.sh" <<'EOF2'
#!/usr/bin/env bash
v="$1"; shift
echo "issue/jira $v $*" >> "$DEVAGENT_STUB_LOG"
case "$v" in
  state-class) echo "usage: jira.sh <verb> ..." >&2; exit "${STUB_JIRA_SC_RC:-2}" ;;
esac
exit 0
EOF2
    chmod +x "$DEVAGENT_TMP/fake-issue/jira.sh"
}
JIRA_R7="cannot read Issue-2 tracker state on jira; merge order is yours: record its PR as [context.Issue-2].mr_url, or merge by hand, then mark this step [x] with /devagent:checklist-mark"

@test "#885 deps: a dependency on a tracker without state-class and no mr_url waits with the remedy" {
    _jira_tracker
    _deps Issue-2
    _run
    _wait_is 7 "$JIRA_R7"
    [ "$(_calls issue-mrs)" -eq 0 ]
    [ "$(_calls merge-mr)" -eq 0 ]
    devagent_assert_logged "issue/jira state-class ACME 2"
    STUB_JIRA_SC_RC=78 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is 7 "$JIRA_R7"
    [ "$(_calls issue-mrs)" -eq 0 ]
    [ "$(_calls merge-mr)" -eq 0 ]
}

@test "#885 deps: a dependency on a tracker without state-class with a merged mr_url is satisfied" {
    _setb permissions.merge_mr false
    _jira_tracker
    _deps Issue-2; _dep_url Issue-2
    echo MERGED > "$STUB_DIR/mrstate.2"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    [ "$(_calls issue-mrs)" -eq 0 ]
    devagent_refute_logged "state-class"
}

# ---- rules 9-18: only when the step would merge -----------------------------------

@test "#885 R9: a PR on another repo than ship's target is [!]" {
    devagent_state_set "$STATE" mr_url "https://github.com/evil/testproj/pull/77"
    _run
    _stop_is 9 "PR is not on acme/testproj; it is on evil/testproj. Fix mr_url or code_source, then run /devagent:unstuck"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R9: no code_source.upstream is a config [!], not a repo mismatch" {
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.upstream"
    _run
    _stop_is 9 "no code_source.upstream configured for 'testproj'; set it, then run /devagent:unstuck"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R10: no verified_head is [!]" {
    devagent_state_set "$STATE" verified_head ""
    _run
    _stop_is 10 "no verified head for this PR; run /devagent:preship"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R11: a head that is not verified_head is [!], no merge-mr call" {
    _view head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    _run
    _stop_is 11 "PR head bbbbbbb was not verified; run /devagent:preship on it (or push the verified head ${PR_HEAD:0:7})"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R11: a verified head that was never pushed names the push remedy" {
    devagent_state_set "$STATE" verified_head cccccccccccccccccccccccccccccccccccccccc
    _run
    _stop_is 11 "PR head ${PR_HEAD:0:7} was not verified; run /devagent:preship on it (or push the verified head ccccccc)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R11 with automerge calls --disable-auto first" {
    _view head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb automerge=on
    _run
    _stop_is 11 "PR head bbbbbbb was not verified; run /devagent:preship on it (or push the verified head ${PR_HEAD:0:7}) (auto-merge disabled)"
    [ "$(cat "$MERGE_LOG")" = "$(printf '[%s]\n' "$URL" --disable-auto; echo --)" ]
    [ "$(_merges)" -eq 0 ]
}

@test "#885 R11 with automerge: a failed disable says so" {
    _view head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb automerge=on
    export MERGE_RC=1 STUB_MERGE_ERR="GraphQL: Pull request auto merge is not allowed"
    _run
    _stop_is 11 "PR head bbbbbbb was not verified; run /devagent:preship on it (or push the verified head ${PR_HEAD:0:7}) (could not disable auto-merge: GraphQL: Pull request auto merge is not allowed; disable it on the forge)"
    [ "$(_merges)" -eq 0 ]
}

@test "#885 unverified: a commit after preship, pushed by ship, is R11" {
    devagent_state_set "$STATE" verified_head ""
    devagent_state_set "$STATE" mr_url ""
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" pin "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" record "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    ( cd "$SOURCE_DIR" && echo late > late.txt && git add late.txt && git commit -q -m late )
    local h2; h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    # ship pushes the branch tip and records the PR
    devagent_state_set "$STATE" mr_url "$URL"
    _view head="$h2"
    _run
    _stop_is 11 "PR head ${h2:0:7} was not verified; run /devagent:preship on it (or push the verified head ${PR_HEAD:0:7})"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 unverified: a commit pushed after ship is R11" {
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" pin "$TEST_PROJECT"
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" record "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    _setb permissions.merge_mr false
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN)"
    ( cd "$SOURCE_DIR" && echo fix > fix.txt && git add fix.txt && git commit -q -m fix )
    local h2; h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _view head="$h2"
    _setb permissions.merge_mr true
    _run
    _stop_is 11 "PR head ${h2:0:7} was not verified; run /devagent:preship on it (or push the verified head ${PR_HEAD:0:7})"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R12: automerge on waits, no merge-mr call" {
    _view automerge=on
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R12: in a merge queue waits, no merge-mr call" {
    _view queue=true mergestate=BLOCKED
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/BLOCKED)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R12 reason shows red CI" {
    _view automerge=on checks="fail:ci"
    _run
    _wait_is 12 "merge accepted; waiting (red, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R13: mergeable UNKNOWN waits" {
    _view mergeable=UNKNOWN mergestate=UNKNOWN
    _run
    _wait_is 13 "mergeability not computed yet"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R13: mergestate UNKNOWN with MERGEABLE waits" {
    _view mergestate=UNKNOWN
    _run
    _wait_is 13 "mergeability not computed yet"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R14: CONFLICTING is [!]" {
    _view mergeable=CONFLICTING mergestate=DIRTY
    _run
    _stop_is 14 "conflict with main; merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R15: red CI is [!] naming the failing check" {
    _view checks="pass:lint fail:ci"
    _run
    _stop_is 15 "CI FAILED: $URL (head ${PR_HEAD:0:7}): ci; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R15: red with another check pending is [!]" {
    _view checks="fail:lint pending:ci"
    _run
    _stop_is 15 "CI FAILED: $URL (head ${PR_HEAD:0:7}): lint; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
}

@test "#885 R15: ci_gate=off still reaches R15" {
    _set ci_gate off
    _view checks="fail:ci"
    _run
    _stop_is 15 "CI FAILED: $URL (head ${PR_HEAD:0:7}): ci; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
}

@test "#885 R16: pending CI waits with the CI line alone" {
    _view checks="pass:lint pending:ci"
    _run
    _wait_is 16 "CI PENDING: 1 of 2 checks still running on $URL (head ${PR_HEAD:0:7}): ci"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R16: BLOCKED with a check pending waits" {
    _view checks="pending:ci" mergestate=BLOCKED
    _run
    _wait_is 16 "CI PENDING: 1 of 1 checks still running on $URL (head ${PR_HEAD:0:7}): ci"
}

@test "#885 R16: no checks inside the grace waits" {
    _view checks=""
    _run
    _wait_is 16 "checks not reported yet (grace 120s)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R17: no checks after the grace is [!] under required" {
    _view checks=""
    devagent_state_set "$STATE" ci_seen_head "$PR_HEAD"
    devagent_state_set "$STATE" ci_seen_at 1000
    _run
    _stop_is 17 "no CI checks on head commit; set merge_checks = \"if-present\" to merge without CI, then run /devagent:unstuck"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R18: BLOCKED with CI green is [!]" {
    _view mergestate=BLOCKED
    _run
    _stop_is 18 "blocked by a forge rule (BLOCKED); resolve it on the forge, then run /devagent:unstuck"
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 R18: BEHIND is [!]" {
    _view mergestate=BEHIND
    _run
    _stop_is 18 "blocked by a forge rule (BEHIND); resolve it on the forge, then run /devagent:unstuck"
}

@test "#885 [!] writes STUCK naming mergemr, logged under the mergemr tag" {
    _view mergestate=BLOCKED
    _run
    [ "$status" -eq 1 ]
    grep -qE '^Reason:[[:space:]]+mergemr rule 18: ' "$ISSUE_DIR/STUCK"
    _mrlog | grep -qxF "STUCK: mergemr rule 18: blocked by a forge rule (BLOCKED); resolve it on the forge, then run /devagent:unstuck"
}

# ---- rule 19: the merge ----------------------------------------------------------------

# _argv <elem>...: the MERGE_LOG text of one merge-mr call with these argv elements.
_argv() { printf '[%s]\n' "$@"; echo --; }

@test "#885 green: squash merges with method, match-head, subject and body; marks [x]" {
    _view closes="acme/testproj 5;Other-Org/tracker 12" \
          trailers="Signed-off-by: Tess <tess@example.com>;Co-authored-by: Bot <bot@example.com>"
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    echo "$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method squash --match-head-commit "$PR_HEAD" \
        --subject "Add the thing (#77)" \
        --body "$(printf 'Closes #5\nCloses Other-Org/tracker#12\n\nSigned-off-by: Tess <tess@example.com>\nCo-authored-by: Bot <bot@example.com>')")" ]
    _mrlog | grep -qxF "merged $URL by squash at $PR_HEAD → cccccccccccccccccccccccccccccccccccccccc"
    grep -qE '^last_step = "20"' "$STATE"
    [ "$(_transitions)" -eq 1 ]
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 green: body keeps Signed-off-by, drops Co-authored-by under include_coauthor=false, writes owner/name#N" {
    _setb include_coauthor false
    _view closes="Other-Org/tracker 12" \
          trailers="Co-authored-by: Bot <bot@example.com>;Signed-off-by: Ann <ann@example.com>;signed-off-by: Bob <bob@example.com>"
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method squash --match-head-commit "$PR_HEAD" \
        --subject "Add the thing (#77)" \
        --body "$(printf 'Closes Other-Org/tracker#12\n\nSigned-off-by: Ann <ann@example.com>\nsigned-off-by: Bob <bob@example.com>')")" ]
}

@test "#885 green: a PR that only says Related: #N gets no Closes line" {
    _view closes=""
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method squash --match-head-commit "$PR_HEAD" \
        --subject "Add the thing (#77)" --body "Signed-off-by: Tess <tess@example.com>")" ]
}

@test "#885 green: squash with no closes and no trailers still passes an empty --body" {
    _view trailers=""
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method squash --match-head-commit "$PR_HEAD" \
        --subject "Add the thing (#77)" --body "")" ]
}

@test "#885 green: rebase passes no subject or body" {
    _set merge_method rebase
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method rebase --match-head-commit "$PR_HEAD")" ]
    _mrlog | grep -qxF "merged $URL by rebase at $PR_HEAD → cccccccccccccccccccccccccccccccccccccccc"
}

@test "#885 green: [defaults] merge_method applies" {
    devagent_config_set "$CFG" defaults.merge_method merge
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(cat "$MERGE_LOG")" = "$(_argv "$URL" --method merge --match-head-commit "$PR_HEAD")" ]
}

@test "#885 R9: a fork_first PR on the fork passes (case-insensitive) and merges" {
    _setb fork_first true
    devagent_state_set "$STATE" mr_url "https://github.com/Me/TestProj/pull/77"
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#885 R17: no checks after the grace merges under if-present" {
    _set merge_checks if-present
    _view checks=""
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    devagent_state_set "$STATE" ci_seen_head "$PR_HEAD"
    devagent_state_set "$STATE" ci_seen_at 1000
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#885 merge accepted with auto-merge on: [?]; the next run is R12 with no second merge-mr" {
    _view out=after automerge=on
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting (19): merge accepted; PR still open (merge queue or auto-merge)"* ]]
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _mrlog | grep -qxF "merge accepted $URL by squash at $PR_HEAD; PR still open"
    [ "$(_merges)" -eq 1 ]
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ "$(_merges)" -eq 1 ]
}

@test "#885 merge accepted into a merge queue: [?]; the next run is R12 with no second merge-mr" {
    _view out=after queue=true
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting (19): merge accepted; PR still open (merge queue or auto-merge)"* ]]
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ "$(_merges)" -eq 1 ]
}

@test "#885 a PR ejected from the queue falls through to the merge" {
    _view queue=true
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
    _view queue=false
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#885 a disallowed method is [!] with gh's text" {
    _set merge_method merge
    export MERGE_RC=1 STUB_MERGE_ERR="GraphQL: Merge commits are not allowed on this repository (mergePullRequest)"
    _run
    _stop_is 19 "merge call failed: GraphQL: Merge commits are not allowed on this repository (mergePullRequest); then run /devagent:unstuck"
    [ "$(_merges)" -eq 1 ]
    [ "$(_transitions)" -eq 0 ]
}

@test "#885 a merge-mr timeout is [!]" {
    export STUB_MERGE_SLEEP=10 DEVAGENT_MERGEMR_MERGE_SECS=1
    _run
    _stop_is 19 "merge call failed: timed out after 1s; then run /devagent:unstuck"
}

@test "#885 a failed or timed-out re-read after the merge waits, no STUCK" {
    export STUB_VIEW_AFTER_RC=1
    _run
    _wait_is 19 "could not read PR after merge: stub: re-read failed"
    [ "$(_merges)" -eq 1 ]
    rm -f "$STUB_DIR/merged" "$MERGE_LOG"
    unset STUB_VIEW_AFTER_RC
    export STUB_VIEW_AFTER_SLEEP=10 DEVAGENT_MERGEMR_READ_SECS=1
    _run
    _wait_is 19 "could not read PR after merge: timed out after 1s"
}

@test "#885 a PR found closed on the re-read is rule 4" {
    _view out=after state=closed
    _run
    _stop_is 4 "PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"
}

@test "#885 squash with more commits than were read is [!]; merge_method=merge still merges" {
    _view commits="120 100"
    _run
    _stop_is 19 "PR has 120 commits but 100 were read; the squash trailers would be incomplete. Merge it by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark"
    [ ! -e "$MERGE_LOG" ]
    bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    _set merge_method merge
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
}

@test "#885 quiet waiting: three unchanged waits log once; a changed reason logs again" {
    _view draft=true
    _run; _run; _run
    _wait_is 5 "draft PR"
    [ "$(_mrlog | grep -cxF 'waiting (5): draft PR')" -eq 1 ]
    _view base=dev
    _run
    _wait_is 6 "stacked on dev"
    _view draft=true
    _run
    [ "$(_mrlog | grep -cxF 'waiting (5): draft PR')" -eq 2 ]
    [ "$(_mrlog | grep -cxF 'waiting (6): stacked on dev')" -eq 1 ]
}

@test "#885 quiet waiting: an unchanged wait in a CRLF checklist logs once" {
    _view draft=true
    _run
    _wait_is 5 "draft PR"
    sed -i 's/\r*$/\r/' "$CL"
    _run; _run
    [ "$status" -eq 0 ]
    [ "$(_mrlog | tr -d '\r' | grep -cxF 'waiting (5): draft PR')" -eq 1 ]
}

# ---- on_merge ---------------------------------------------------------------------------

_marker() { grep -E '^- [0-9-]+ [0-9:]+  sync: .* merged' "$CL" | sed -E 's/^- [0-9-]+ [0-9:]+  //'; }

@test "#885 on_merge fires once across mergemr then sync" {
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(_transitions)" -eq 1 ]
    STUB_MRSTATE=MERGED run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ "$(_transitions)" -eq 1 ]
    [ "$(_marker | wc -l)" -eq 1 ]
}

@test "#885 on_merge fires once across sync then mergemr" {
    mark_step "$CL" 20 '?'
    STUB_MRSTATE=MERGED run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ "$(_transitions)" -eq 1 ]
    assert_step "$CL" 20 ' ' mergemr
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_transitions)" -eq 1 ]
    [ "$(_marker | wc -l)" -eq 1 ]
}

@test "#885 the marker line mergemr writes equals sync's byte-for-byte" {
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(_marker)" = 'sync: Issue-1 merged → on_merge landed: "Done" on acme/testproj' ]
}

@test "#885 transition_issue=false: no call, no marker; enabling it later fires once" {
    _setb permissions.transition_issue false
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_transitions)" -eq 0 ]
    [ -z "$(_marker)" ]
    _setb permissions.transition_issue true
    _run
    [ "$status" -eq 0 ]
    [ "$(_transitions)" -eq 1 ]
    _run
    [ "$(_transitions)" -eq 1 ]
}

@test "#885 an 'unmerged' mergemr line is not a merge marker" {
    _view state=closed
    _run
    [ "$status" -eq 1 ]
    grep -qF 'mergemr: STUCK: mergemr rule 4: PR closed unmerged' "$CL"
    [ -z "$(_marker)" ]
    bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    _view state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    [ "$(_transitions)" -eq 1 ]
}

# ---- other backends ---------------------------------------------------------------------

_gitlab() { _set code_source.backend gitlab; }

@test "#885 other backend: mr-state merged/closed/open give [x]/[!]/[?] under both merge_mr values" {
    _gitlab
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        rm -f "$ISSUE_DIR/STUCK"; mark_step "$CL" 20 ' '
        STUB_MRSTATE=MERGED run "$MM" "$TEST_PROJECT" </dev/null
        [ "$status" -eq 0 ]
        assert_step "$CL" 20 x mergemr
        _mrlog | grep -qxF "PR $URL merged (merge commit -)"
        STUB_MRSTATE=closed run "$MM" "$TEST_PROJECT" </dev/null
        _stop_is 4 "PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"
        rm -f "$ISSUE_DIR/STUCK"; mark_step "$CL" 20 ' '
        STUB_MRSTATE=OPEN run "$MM" "$TEST_PROJECT" </dev/null
        _wait_is 8 "waiting for merge (merge step supports github only)"
    done
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
    [ "$(_transitions)" -eq 1 ]
}

@test "#885 other backend: a draft mr-state is the rule 5 [?] under both merge_mr values" {
    _gitlab
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        STUB_MRSTATE=draft run "$MM" "$TEST_PROJECT" </dev/null
        _wait_is 5 "draft PR"
    done
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 other backend: mr-state exiting 78 or 2 is the cannot-read [?] under both merge_mr values" {
    _gitlab
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        for rc in 78 2; do
            STUB_MRSTATE_RC=$rc run "$MM" "$TEST_PROJECT" </dev/null
            _wait_is read "cannot read PR state on gitlab; merge by hand, then mark this step [x] with /devagent:checklist-mark"
        done
    done
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 other backend: a failed or timed-out mr-state is the read [?]" {
    _gitlab
    STUB_MRSTATE_RC=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read PR $URL: stub: mr-state failed"
    STUB_MRSTATE_SLEEP=10 DEVAGENT_MERGEMR_READ_SECS=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read PR $URL: timed out after 1s"
}

@test "#885 other backend: ship [-] and no mr_url keep rules 1-2" {
    _gitlab
    devagent_state_set "$STATE" mr_url ""
    _run
    _stop_is 2 "no PR URL recorded for this issue; merge the PR by hand, then run /devagent:unstuck and mark this step [x] with /devagent:checklist-mark"
    [ "$(_calls mr-state)" -eq 0 ]
}

# ---- remedy execution (Issue-594): run each message's own steps ----------------------

@test "#885 remedy R2: merge by hand, unstuck, mark [x]" {
    devagent_state_set "$STATE" mr_url ""
    _run
    [ "$status" -eq 1 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" mergemr x
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 remedy R4: unstuck, mark [-]" {
    _view state=closed
    _run
    [ "$status" -eq 1 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" mergemr -
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 - mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

# _preship: the post-ship preship's two script calls around the verifier (preship.md).
_preship() {
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" pin "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    run "$DEVAGENT_ROOT/scripts/preship-verified-head.sh" record "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
}

@test "#885 remedy R10: run preship; the stop clears and the next run merges" {
    devagent_state_set "$STATE" verified_head ""
    _run
    [ "$status" -eq 1 ]
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
}

@test "#885 remedy R14: merge forward, rebaseline, push, preship; the next run merges" {
    local origin="$DEVAGENT_TMP/origin.git" upwc="$DEVAGENT_TMP/upwc" h2
    git -c init.defaultBranch=main init -q --bare "$origin"
    ( cd "$SOURCE_DIR" && git remote add origin "$origin" && git push -q origin main && git fetch -q origin )
    git clone -q -b main "$origin" "$upwc"
    ( cd "$upwc" && git config user.email u@example.com && git config user.name U \
      && echo up > up.txt && git add up.txt && git commit -q -m up && git push -q origin main )
    _view mergeable=CONFLICTING mergestate=DIRTY
    _run
    [ "$status" -eq 1 ]
    ( cd "$SOURCE_DIR" && git fetch -q origin && git merge -q --no-edit origin/main )
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _view head="$h2"                       # pushed: the PR now shows the merged-forward head
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    grep -qxF "[$h2]" "$MERGE_LOG"
}

@test "#885 remedy R15: fix, push, preship; the next run merges" {
    local h2
    _view checks="fail:ci"
    _run
    [ "$status" -eq 1 ]
    ( cd "$SOURCE_DIR" && echo fix > fix.txt && git add fix.txt && git commit -q -m fix )
    h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _view head="$h2"
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    grep -qxF "[$h2]" "$MERGE_LOG"
}

@test "#885 remedy R17: set merge_checks = if-present, unstuck; the next run merges" {
    _view checks=""
    devagent_state_set "$STATE" ci_seen_head "$PR_HEAD"
    devagent_state_set "$STATE" ci_seen_at 1000
    _run
    [ "$status" -eq 1 ]
    _set merge_checks if-present
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

@test "#885 remedy trailer truncation: merge by hand, unstuck, mark [x]" {
    _view commits="120 100"
    _run
    [ "$status" -eq 1 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" mergemr x
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#885 remedy failed merge: unstuck; the next run merges" {
    export MERGE_RC=1
    _run
    [ "$status" -eq 1 ]
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
    unset MERGE_RC
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    [ "$(_merges)" -eq 2 ]
}

# ---- the real code backend ----------------------------------------------------------------

@test "#885 real backend leg: mergemr.sh -> code/github.sh -> gh shows [--body] []" {
    unset DEVAGENT_CODE_BACKEND_DIR
    mkdir -p "$DEVAGENT_TMP/ghbin" "$DEVAGENT_TMP/gql"
    cp "$DEVAGENT_ROOT/tests/fixtures/gh-stub" "$DEVAGENT_TMP/ghbin/gh"
    chmod +x "$DEVAGENT_TMP/ghbin/gh"
    export PATH="$DEVAGENT_TMP/ghbin:$PATH"
    export GH_STUB_GRAPHQL_DIR="$DEVAGENT_TMP/gql"
    cp "$DEVAGENT_ROOT/tests/fixtures/code-github/mr-view-gql-open.json" "$GH_STUB_GRAPHQL_DIR/1.json"
    cp "$DEVAGENT_ROOT/tests/fixtures/code-github/mr-view-gql-open.json" "$GH_STUB_GRAPHQL_DIR/2.json"
    jq --arg h "$PR_HEAD" '.headRefOid = $h | .closingIssuesReferences = []
        | .commits |= map(.messageBody = "no trailers here")' \
        "$DEVAGENT_ROOT/tests/fixtures/code-github/mr-view-open.json" > "$DEVAGENT_TMP/pr-view.json"
    export GH_STUB_PR_VIEW_FILE="$DEVAGENT_TMP/pr-view.json"
    export GH_STUB_PR_MERGE_LOG="$DEVAGENT_TMP/gh-merge.log"
    _run
    echo "$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting (19): merge accepted; PR still open (merge queue or auto-merge)"* ]]
    cat "$GH_STUB_PR_MERGE_LOG" >&2
    [ "$(sed -n 1p "$GH_STUB_PR_MERGE_LOG")" = "[pr] [merge] [$URL] [--squash] [--match-head-commit] [$PR_HEAD] [--subject] [Fix the volk thing (#9)] [--body] []" ]
    [ "$(sed -n 2p "$GH_STUB_PR_MERGE_LOG")" = "GH_PROMPT_DISABLED=1 stdin=notty" ]
    [ "$(wc -l < "$GH_STUB_PR_MERGE_LOG")" -eq 2 ]
}

# ---- commands/mergemr.md (Issue-461: a doc an agent executes is product behaviour) ----

@test "#885 every fenced command in commands/mergemr.md runs with its placeholders filled" {
    local doc="$DEVAGENT_ROOT/commands/mergemr.md" line cmd n=0
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    while IFS= read -r line; do
        n=$((n + 1))
        cmd="${line//<project>/$TEST_PROJECT}"
        cmd="${cmd//<issue-dir>/$ISSUE_DIR}"
        cmd="${cmd// \[issue\]/}"
        [[ "$cmd" != *'<'* && "$cmd" != *'['[a-z]* ]] || { echo "unfilled placeholder: $line" >&2; return 1; }
        CLAUDE_PLUGIN_ROOT="$DEVAGENT_ROOT" run bash -c "$cmd" </dev/null
        echo "cmd=[$cmd] status=$status output=$output" >&2
        [ "$status" -eq 0 ]
        [[ "$output" != *usage:* ]]
    done < <(awk '/^```/ { f = !f; next } f && /^bash "\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\// { print }' "$doc")
    [ "$n" -eq 3 ]
    assert_step "$CL" 20 - mergemr
    # the bang line hands the script the command's arguments unchanged
    grep -qxF '!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergemr.sh" $ARGUMENTS`' "$doc"
}
