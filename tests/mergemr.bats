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
# from files under $STUB_DIR; every call is counted in $STUB_DIR/calls; mr-checks is an
# unknown verb (exit 2) unless a test serves $MC_OUT (#1097, _checks). Stub issue
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
  mr-checks)
    [ -n "${MC_OUT:-}" ] || exit 2
    [ -z "${STUB_CHECKS_SLEEP:-}" ] || exec sleep "$STUB_CHECKS_SLEEP"
    if [ "${STUB_CHECKS_RC:-0}" != 0 ]; then echo "stub: mr-checks failed" >&2; exit "$STUB_CHECKS_RC"; fi
    cat "$MC_OUT" ;;
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
# empty = no checks; a pass line has three fields, as a backend that prints no
# conclusion writes it. rchecks (#1097): `;`-separated <kind>|<name>[|<CONCLUSION>],
# for a name with a space and a line with its conclusion (the fourth field, left out
# when <CONCLUSION> is). closes/trailers: `;`-separated. commits: "<total> <read>".
_view() {
    local -A f=([state]=open [head]="$PR_HEAD" [checks]="pass:ci" [rchecks]="" [draft]=false [base]=main
                [mergeable]=MERGEABLE [mergestate]=CLEAN [automerge]=off [queue]=false
                [number]=77 [title]="Add the thing" [mergecommit]=- [commits]="1 1"
                [closes]="" [trailers]="Signed-off-by: Tess <tess@example.com>" [out]="")
    local kv c item path="$DEVAGENT_TMP/view.txt" k kind name concl
    for kv in "$@"; do f[${kv%%=*}]="${kv#*=}"; done
    if [ "${f[out]}" = after ]; then path="$DEVAGENT_TMP/view-after.txt"; export MV_OUT_AFTER="$path"
    else export MV_OUT="$path"; fi
    {
        printf 'state\t%s\nhead\t%s\n' "${f[state]}" "${f[head]}"
        for c in ${f[checks]}; do
            if [ "${c%%:*}" = fail ]; then printf 'fail\t%s\t-\tFAILURE\n' "${c#*:}"
            else printf '%s\t%s\t-\n' "${c%%:*}" "${c#*:}"; fi
        done
        IFS=';' read -ra items <<<"${f[rchecks]}"
        for item in "${items[@]}"; do
            [ -n "$item" ] || continue
            IFS='|' read -r kind name concl <<<"$item"
            if [ -n "$concl" ]; then printf '%s\t%s\t-\t%s\n' "$kind" "$name" "$concl"
            else printf '%s\t%s\t-\n' "$kind" "$name"; fi
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
    # #1125: no origin remote here, so the conflicted paths are unknown.
    _view mergeable=CONFLICTING mergestate=DIRTY
    _run
    _stop_is 14 "conflict with main (conflicted paths unknown: cannot resolve origin/main); $R14_TODAY"
    [ ! -e "$MERGE_LOG" ]
}

# ---- #1125: rule 14 names the conflicted paths and the remedy ------------------

R14_TODAY="merge it forward, run rebaseline.sh, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
R14_LIGHT="merge it forward keeping both sides' lines, run rebaseline.sh, push, then run preship-verified-head.sh forward"

# _r14_origin: a bare origin whose main and the PR head (verified_head) each add a
# different ## [Unreleased] entry to CHANGELOG.md; the forge says CONFLICTING.
_r14_origin() {
    ORIGIN="$DEVAGENT_TMP/origin.git" UPWC="$DEVAGENT_TMP/upwc"
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    ( cd "$SOURCE_DIR" && git checkout -q main \
      && printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n- old\n' > CHANGELOG.md \
      && git add CHANGELOG.md && git commit -q -m changelog \
      && git remote add origin "$ORIGIN" && git push -q origin main && git fetch -q origin \
      && git checkout -q feat/1-x && git rebase -q main \
      && sed -i '/^## \[Unreleased\]$/a - ours entry' CHANGELOG.md && git commit -q -am ours )
    PR_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$STATE" verified_head "$PR_HEAD"
    git clone -q -b main "$ORIGIN" "$UPWC"
    ( cd "$UPWC" && git config user.email u@example.com && git config user.name U \
      && sed -i '/^## \[Unreleased\]$/a - theirs entry' CHANGELOG.md && git commit -q -am theirs \
      && git push -q origin main )
    printf '# Issue-1 MR\n\nA change.\n' > "$ISSUE_DIR/mr.md"
    _view head="$PR_HEAD" mergeable=CONFLICTING mergestate=DIRTY
}

_mf() {   # _mf <verify-literal|-> <append_only-literal|->
    {
        printf '\n[project.%s.merge_forward]\n' "$TEST_PROJECT"
        [ "$1" = - ] || printf 'verify = %s\n' "$1"
        [ "$2" = - ] || printf 'append_only = %s\n' "$2"
    } >> "$CFG"
}

@test "#1125 R14: light remedy when verify = ci and only CHANGELOG.md conflicts" {
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    _run
    _stop_is 14 "conflict only in CHANGELOG.md; $R14_LIGHT"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1125 R14: verify absent gives today's remedy naming the paths" {
    _r14_origin
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a conflicted path outside append_only gives today's remedy" {
    _r14_origin
    ( cd "$SOURCE_DIR" && echo ours > z.txt && git add z.txt && git commit -q -m z )
    PR_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$STATE" verified_head "$PR_HEAD"
    ( cd "$UPWC" && echo theirs > z.txt && git add z.txt && git commit -q -m z && git push -q origin main )
    _view head="$PR_HEAD" mergeable=CONFLICTING mergestate=DIRTY
    _mf '"ci"' '["CHANGELOG.md"]'
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md, z.txt; $R14_TODAY"
}

@test "#1125 R14: mr.md with a merge gate gives today's remedy" {
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    printf '# Issue-1 MR\n\n**Merge gate:** a flag first.\n' > "$ISSUE_DIR/mr.md"
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a conflicted path with a merge driver gives today's remedy" {
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    # A driver that gives up still leaves git a conflict; forward would refuse the
    # driver (merge_forward_driver), so the light remedy is withheld.
    echo 'CHANGELOG.md merge=giveup' >> "$SOURCE_DIR/.git/info/attributes"
    git -C "$SOURCE_DIR" config merge.giveup.driver false
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a listed path git did not merge as text gives today's remedy" {
    # modify/delete leaves no stage 3: forward refuses it ("did not merge as text"),
    # so rule 14 must not offer it.
    _r14_origin
    ( cd "$UPWC" && git rm -q CHANGELOG.md && git commit -q -m rm && git push -q origin main )
    _mf '"ci"' '["CHANGELOG.md"]'
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a hunk with a non-empty base section gives today's remedy" {
    # The base also rewrote the heading next to both insertions, so the hunk carries
    # a base line: forward always refuses that, so rule 14 must not offer it (review I2).
    _r14_origin
    ( cd "$UPWC" && sed -i 's/^## \[Unreleased\]$/## [Unreleased] (next)/' CHANGELOG.md \
      && git commit -q -am heading && git push -q origin main )
    _mf '"ci"' '["CHANGELOG.md"]'
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a conflict git reports without a conflicted path says the paths are unknown" {
    # A directory rename split: merge-tree exits 1 with no conflicted-file record
    # (review I1: this crashed rule 14 with a bash subscript error).
    ORIGIN="$DEVAGENT_TMP/origin.git" UPWC="$DEVAGENT_TMP/upwc"
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    ( cd "$SOURCE_DIR" && git checkout -q main \
      && mkdir a && for i in 1 2 3 4; do echo "file $i content line" > "a/f$i"; done \
      && git add a && git commit -q -m dir \
      && git remote add origin "$ORIGIN" && git push -q origin main && git fetch -q origin \
      && git checkout -q feat/1-x && git rebase -q main \
      && mkdir b c && git mv a/f1 b/f1 && git mv a/f2 b/f2 && git mv a/f3 c/f3 && git mv a/f4 c/f4 \
      && git commit -q -m split )
    PR_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$STATE" verified_head "$PR_HEAD"
    git clone -q -b main "$ORIGIN" "$UPWC"
    ( cd "$UPWC" && git config user.email u@example.com && git config user.name U \
      && echo new > a/new && git add a/new && git commit -q -m new && git push -q origin main )
    printf '# Issue-1 MR\n\nA change.\n' > "$ISSUE_DIR/mr.md"
    _view head="$PR_HEAD" mergeable=CONFLICTING mergestate=DIRTY
    _run
    _stop_is 14 "conflict with main (conflicted paths unknown: git reports a conflict but names no conflicted path); $R14_TODAY"
}

@test "#1125 R14: a merge driver on any path of the tree withholds the light remedy" {
    # forward refuses a driver on any path of git's merged tree, so rule 14 must not
    # offer it there either (final review I1).
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    echo 'f1.txt merge=giveup' >> "$SOURCE_DIR/.git/info/attributes"
    _run
    _stop_is 14 "conflict with main in CHANGELOG.md; $R14_TODAY"
}

@test "#1125 R14: a failed fetch says the paths are unknown" {
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    git -C "$SOURCE_DIR" remote set-url origin "$DEVAGENT_TMP/gone.git"
    _run
    _stop_is 14 "conflict with main (conflicted paths unknown: could not fetch 'origin' (git fetch exited 128)); $R14_TODAY"
}

@test "#1125 R14: a timed-out fetch says the paths are unknown" {
    _r14_origin
    _mf '"ci"' '["CHANGELOG.md"]'
    printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = fetch ] && exec sleep 30; done\nexec git "$@"\n' > "$DEVAGENT_TMP/gitshim"
    chmod +x "$DEVAGENT_TMP/gitshim"
    DEVAGENT_GIT="$DEVAGENT_TMP/gitshim" DEVAGENT_MERGEMR_FETCH_SECS=1 run "$MM" "$TEST_PROJECT" </dev/null
    _stop_is 14 "conflict with main (conflicted paths unknown: could not fetch 'origin' (timed out after 1s)); $R14_TODAY"
}

@test "#1125 R14: git finds no conflict where the forge reports one" {
    _r14_origin
    ( cd "$UPWC" && git reset -q --hard HEAD~1 && echo up > up.txt && git add up.txt \
      && git commit -q -m up && git push -q -f origin main )
    local tip; tip="$(git -C "$UPWC" rev-parse HEAD)"
    _run
    _stop_is 14 "conflict with main (git finds no conflict between ${PR_HEAD:0:7} and ${tip:0:7}); $R14_TODAY"
}

@test "#1125 R14: an unresolvable issue tree says the paths are unknown" {
    _r14_origin
    devagent_state_set "$STATE" worktree_path "$DEVAGENT_TMP/gone-wt"
    _run
    _stop_is 14 "conflict with main (conflicted paths unknown: cannot resolve the issue tree: active_tree_resolve: recorded worktree_path is not a usable git tree: $DEVAGENT_TMP/gone-wt — refusing to silently measure a different tree instead (#571/#148)); $R14_TODAY"
}

@test "#1125 config: bad merge_forward.verify dies at mergemr start, also with merge_mr false" {
    _mf '"maybe"' -
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        [ "$status" -eq 1 ]
        [[ "$output" == *"merge_forward.verify must be \"ci\" or \"preship\" (got 'maybe'); fix [project.testproj.merge_forward] verify"* ]]
        assert_step "$CL" 20 ' ' mergemr
    done
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#1125 config: append_only as a string dies at mergemr start" {
    _mf '"ci"' '"CHANGELOG.md"'
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.append_only must be an array of strings"*"fix [project.testproj.merge_forward] append_only"* ]]
    [ "$(_calls mr-view)" -eq 0 ]
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
    # #1125: git itself finds no conflict here (the forge's word stands alone).
    [ "$(_reason)" = "mergemr rule 14: conflict with main (git finds no conflict between ${PR_HEAD:0:7} and $(git -C "$upwc" rev-parse HEAD | cut -c1-7)); $R14_TODAY" ]
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

# #713: under a trust policy in scope the policy alone decides merge_mr, and the
# decision is read only AFTER the entry check — a gate read before it saw config.
@test "#713 trust: a policy-closed merge_mr is not opened by config merge_mr=true" {
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<'STUB'
#!/usr/bin/env bash
v="$1"; shift
echo "issue/github $v $*" >> "$DEVAGENT_STUB_LOG"
case "$v" in
  whoami) echo 1001 ;;
  state-class) cat "$STUB_DIR/sc.$2" 2>/dev/null || exit 1 ;;
esac
exit 0
STUB
    local pol="$HOME/.config/devagent/trust"
    mkdir -p "$pol"
    # #714: an in-scope policy carries its quarantine label; the stub's events
    # (exit 0, no records) reads as not quarantined.
    printf '%s\n' 'scopes = ["github:github.com/acme/testproj"]' 'worker_identities = ["github:1001"]' \
        'quarantine = "devagent:quarantine"' > "$pol/policy.toml"
    run "$MM" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ ! -s "$MERGE_LOG" ]
    grep -q 'issue/github whoami' "$DEVAGENT_STUB_LOG"
    # positive control: the policy opens it.
    printf '%s\n' 'merge_mr = true' >> "$pol/policy.toml"
    run "$MM" "$TEST_PROJECT" Issue-1
    [ -s "$MERGE_LOG" ] || { echo "$output" >&2; false; }
}

# ---- #1125: rule 17 for a head recorded by forward ------------------------------

R17_FWD_RECIPE="re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"

# _no_checks_past_grace: the PR head reports no checks, and the grace has run out.
_no_checks_past_grace() {
    _view checks=""
    devagent_state_set "$STATE" ci_seen_head "$PR_HEAD"
    devagent_state_set "$STATE" ci_seen_at 1000
}

@test "#1125 R17: a forwarded head merges on green" {
    devagent_state_set "$STATE" verified_by forward
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
    grep -qxF "[$PR_HEAD]" "$MERGE_LOG"
}

@test "#1125 R17: a forwarded head waits while CI is pending" {
    devagent_state_set "$STATE" verified_by forward
    _view checks="pending:ci"
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting (16): "* ]]
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R17: a forwarded head stops at rule 15 on red" {
    devagent_state_set "$STATE" verified_by forward
    _view checks="fail:ci"
    _run
    _stop_is 15 "CI FAILED: $URL (head ${PR_HEAD:0:7}): ci; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R17: a forwarded head with no checks stops under required" {
    devagent_state_set "$STATE" verified_by forward
    _no_checks_past_grace
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none); to verify it in full, $R17_FWD_RECIPE"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R17: a forwarded head with no checks stops under if-present" {
    _set merge_checks if-present
    devagent_state_set "$STATE" verified_by forward
    _no_checks_past_grace
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none); to verify it in full, $R17_FWD_RECIPE"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R17: a passing record clears the forward rule-17 stop; the next run merges under if-present" {
    _set merge_checks if-present
    devagent_state_set "$STATE" verified_by forward
    _no_checks_past_grace
    _run
    [ "$status" -eq 1 ]
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#1125 R17: a head recorded by record behaves as today under if-present" {
    _set merge_checks if-present
    devagent_state_set "$STATE" verified_by preship
    _no_checks_past_grace
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#1125 R17: a legacy record with no verified_by behaves as today" {
    _set merge_checks if-present
    _no_checks_past_grace
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ "$(_merges)" -eq 1 ]
}

@test "#1125 R17: a garbled verified_by is treated as forward" {
    _set merge_checks if-present
    devagent_state_set "$STATE" verified_by forwrad
    _no_checks_past_grace
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none); to verify it in full, $R17_FWD_RECIPE"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R12: a forwarded head with auto-merge on and no checks: auto-merge off, then rule 17" {
    devagent_state_set "$STATE" verified_by forward
    _no_checks_past_grace
    _view checks="" automerge=on
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none); to verify it in full, $R17_FWD_RECIPE"
    [[ "$output" == *"mergemr: auto-merge disabled: head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none)"* ]]
    _mrlog | grep -qxF "auto-merge disabled: head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (none)"
    [ "$(cat "$MERGE_LOG")" = "$(printf '[%s]\n' "$URL" --disable-auto; echo --)" ]
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R12: a forwarded head with auto-merge on and CI pending: auto-merge off, then rule 16 waits" {
    devagent_state_set "$STATE" verified_by forward
    _view checks="pending:ci" automerge=on
    _run
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: auto-merge disabled: "* ]]
    [[ "$output" == *"mergemr: waiting (16): "* ]]
    grep -qxF -- "[--disable-auto]" "$MERGE_LOG"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R12: a forwarded head with auto-merge on and green CI waits, no merge-mr call" {
    devagent_state_set "$STATE" verified_by forward
    _view automerge=on
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1125 R12: a forwarded head in a merge queue without green CI stops, no merge-mr call" {
    devagent_state_set "$STATE" verified_by forward
    _view queue=true mergestate=BLOCKED checks="pending:ci"
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (pending), but the PR is in a merge queue; remove it from the queue on the forge, then run /devagent:unstuck"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1125 R12: a forwarded head whose auto-merge cannot be disabled stops" {
    devagent_state_set "$STATE" verified_by forward
    _view checks="pending:ci" automerge=on
    export MERGE_RC=1 STUB_MERGE_ERR="GraphQL: Pull request auto merge is not allowed"
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (pending); could not disable auto-merge: GraphQL: Pull request auto merge is not allowed; disable it on the forge, then run /devagent:unstuck"
    [ "$(_merges)" -eq 0 ]
}

@test "#1125 R12: a passing record clears the queue stop for a forwarded head" {
    devagent_state_set "$STATE" verified_by forward
    _view queue=true mergestate=BLOCKED checks="pending:ci"
    _run
    [ "$status" -eq 1 ]
    _preship
    [ ! -e "$ISSUE_DIR/STUCK" ]
    assert_step "$CL" 20 ' ' mergemr
}

@test "#1125 R17: a backend without mr-view never merges a forwarded head" {
    devagent_state_set "$STATE" verified_by forward
    STUB_VIEW_RC=78 run "$MM" "$TEST_PROJECT" </dev/null
    echo "status=$status output=$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 '?' mergemr
    [[ "$output" == *"mergemr: waiting (read): "* ]]
    _mrlog | grep -q '^waiting (read): '
    [ "$(_merges)" -eq 0 ]
}

# ---- #1097: required checks ------------------------------------------------------
# `[project.<p>] required_checks` names the check runs the merge needs: each must be
# `pass` + SUCCESS at the verified head. The default fixture stays key-less, and its
# `pass ci -` line is the ordinary check that prints no conclusion.

GBT="Git Bash tagged files"
RC_BAD_REMEDY="re-run the job on the forge and run /devagent:unstuck, or fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
RC_MISSING_REMEDY="start it on the forge and run /devagent:unstuck, or push a head that runs it, then run /devagent:preship"

# _proj_key <key> <toml value>: insert `<key> = <value>` right after the
# [project.$TEST_PROJECT] header (`_toml.py set` stores an array as a string). Fails
# unless exactly one header took the insert: an edit that no-ops must not pass.
_proj_key() {
    local line out="" n=0
    while IFS= read -r line; do
        out+="$line"$'\n'
        if [ "$line" = "[project.$TEST_PROJECT]" ]; then out+="$1 = $2"$'\n'; n=$((n + 1)); fi
    done < "$CFG"
    [ "$n" -eq 1 ] || { echo "_proj_key: [project.$TEST_PROJECT] matched $n header lines in $CFG" >&2; return 1; }
    printf '%s' "$out" > "$CFG"
}

# _req '<toml array>': required_checks, read back as an array of strings.
_req() {
    _proj_key required_checks "$1"
    python3 "$DEVAGENT_ROOT/scripts/lib/_toml.py" get-list "$CFG" "project.$TEST_PROJECT.required_checks" >/dev/null \
        || { echo "_req: get-list does not read required_checks as an array" >&2; return 1; }
}

# _past_grace: the head's grace clock ran out long ago.
_past_grace() {
    devagent_state_set "$STATE" "context.Issue-1.ci_seen_head" "$PR_HEAD"
    devagent_state_set "$STATE" "context.Issue-1.ci_seen_at" 1000
}

_unstuck() {
    run bash "$DEVAGENT_ROOT/scripts/checklist-unstuck.sh" --pending "$ISSUE_DIR"
    [ "$status" -eq 0 ]
}

# _next_run_merges <head>: the PR merges on the next run, at <head>.
_next_run_merges() {
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    echo "status=$status output=$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    [ "$(_merges)" -eq 1 ]
    grep -qxF "[$1]" "$MERGE_LOG"
}

@test "#1097 required: success at the verified head merges" {
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT|SUCCESS"          # beside the ordinary three-field `pass ci -`
    _next_run_merges "$PR_HEAD"
}

@test "#1097 required: pending holds through rule 16" {
    _req "[\"$GBT\"]"
    _view rchecks="pending|$GBT"
    _run
    _wait_is 16 "CI PENDING: 1 of 2 checks still running on $URL (head ${PR_HEAD:0:7}): $GBT"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: failure stops at rule 15 naming the check" {
    _req "[\"$GBT\"]"
    _view rchecks="fail|$GBT|FAILURE"
    _run
    _stop_is 15 "CI FAILED: $URL (head ${PR_HEAD:0:7}): $GBT; fix it, re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: skipped stops" {
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT|SKIPPED"
    _run
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (skipped); $RC_BAD_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: skipped stops while another check is still pending" {
    _req "[\"$GBT\"]"
    _view checks="pending:ci" rchecks="pass|$GBT|SKIPPED"
    _run
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (skipped); $RC_BAD_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: neutral stops" {
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT|NEUTRAL"
    _run
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (neutral); $RC_BAD_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: a pass line with no conclusion fails closed" {
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT"
    _run
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (no conclusion); $RC_BAD_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: missing inside the grace waits, past it stops" {
    _req "[\"$GBT\"]"
    export DEVAGENT_CI_GRACE_SECS=300           # both messages carry the knob, not its default
    _run                                        # `pass ci -` alone: CI is green, the required check absent
    _wait_is 16 "required check not reported yet: $GBT (grace 300s)"
    [ ! -e "$MERGE_LOG" ]
    _past_grace
    _run
    _stop_is 15 "required check not reported on head ${PR_HEAD:0:7} after 300s: $GBT; $RC_MISSING_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: no checks at all past the grace stops naming the check, also under if-present" {
    _req "[\"$GBT\"]"
    _view checks=""
    _past_grace
    _run
    _stop_is 15 "required check not reported on head ${PR_HEAD:0:7} after 120s: $GBT; $RC_MISSING_REMEDY"
    _unstuck
    _set merge_checks if-present
    _view out=after state=merged mergecommit=cccccccccccccccccccccccccccccccccccccccc
    _run
    _stop_is 15 "required check not reported on head ${PR_HEAD:0:7} after 120s: $GBT; $RC_MISSING_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 required: one skipped and one missing are both named" {
    _req "[\"$GBT\", \"lint\"]"
    _view rchecks="pass|$GBT|SKIPPED"
    _run
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (skipped); not reported: lint; $RC_BAD_REMEDY"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 merge_mr=false: the [?] line names each required check and its state at the head" {
    _req "[\"$GBT\", \"lint\", \"docs\"]"
    _setb permissions.merge_mr false
    _view rchecks="pass|$GBT|SUCCESS;pass|lint|SKIPPED"
    _run
    _wait_is 8 "waiting for merge (green, MERGEABLE/CLEAN); required checks at ${PR_HEAD:0:7}: $GBT: success; lint: skipped; docs: missing"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 R12: auto-merge on with every required check successful waits and names them" {
    _req "[\"$GBT\", \"lint\"]"
    _view automerge=on rchecks="pass|$GBT|SUCCESS;pass|lint|SUCCESS"
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN); required checks at ${PR_HEAD:0:7}: $GBT: success; lint: success"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 no key: a skipped check and a three-field pass line merge as today" {
    _view rchecks="pass|$GBT|SKIPPED"          # beside the three-field `pass ci -`
    _next_run_merges "$PR_HEAD"
}

@test "#1097 empty list: auto-merge on with a skipped check waits at rule 12 as today, no disable call" {
    _req '[]'
    _view automerge=on rchecks="pass|$GBT|SKIPPED"
    _run
    _wait_is 12 "merge accepted; waiting (green, MERGEABLE/CLEAN)"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 config: a bad required_checks dies at mergemr start, also with merge_mr false" {
    _proj_key required_checks "\"$GBT\""        # a string where the key takes an array
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        echo "status=$status output=$output" >&2
        [ "$status" -eq 1 ]
        [[ "$output" == *"required_checks must be an array of single-line strings, e.g. required_checks = [\"$GBT\"]; fix [project.testproj] required_checks"* ]]
        assert_step "$CL" 20 ' ' mergemr
    done
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 remedy: re-run on the forge, unstuck; the next run merges" {
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT|SKIPPED"
    _run
    [ "$status" -eq 1 ]
    [[ "$(_reason)" == "mergemr rule 15: required check not successful on head ${PR_HEAD:0:7}: "* ]]
    _view rchecks="pass|$GBT|SUCCESS"           # the re-run job succeeded at the same head
    _unstuck
    _next_run_merges "$PR_HEAD"
}

@test "#1097 remedy: fix, push, preship clears the stop; the next run merges" {
    local h2
    _req "[\"$GBT\"]"
    _view rchecks="pass|$GBT|SKIPPED"
    _run
    [ "$status" -eq 1 ]
    [[ "$(_reason)" == "mergemr rule 15: required check not successful on head ${PR_HEAD:0:7}: "* ]]
    ( cd "$SOURCE_DIR" && echo fix > fix.txt && git add fix.txt && git commit -q -m fix )
    h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _view head="$h2" rchecks="pass|$GBT|SUCCESS"
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _next_run_merges "$h2"
}

@test "#1097 remedy: start the check on the forge, unstuck; the next run merges" {
    _req "[\"$GBT\"]"
    _past_grace
    _run
    [ "$status" -eq 1 ]
    [[ "$(_reason)" == "mergemr rule 15: required check not reported on head ${PR_HEAD:0:7} after 120s: "* ]]
    _view rchecks="pass|$GBT|SUCCESS"           # started by hand, it succeeded at the same head
    _unstuck
    _next_run_merges "$PR_HEAD"
}

@test "#1097 remedy: push a head that runs the check, preship clears the stop; the next run merges" {
    local h2
    _req "[\"$GBT\"]"
    _past_grace
    _run
    [ "$status" -eq 1 ]
    [[ "$(_reason)" == "mergemr rule 15: required check not reported on head ${PR_HEAD:0:7} after 120s: "* ]]
    ( cd "$SOURCE_DIR" && git commit -q --allow-empty -m "run the checks" )
    h2="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    _view head="$h2" rchecks="pass|$GBT|SUCCESS"
    _preship
    assert_step "$CL" 20 ' ' mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _next_run_merges "$h2"
}

R12_REQ="merges only when every required check is successful"

@test "#1097 R12: auto-merge on with a skipped required check turns auto-merge off, then stops at rule 15" {
    _req "[\"$GBT\"]"
    _view automerge=on rchecks="pass|$GBT|SKIPPED"
    _run
    [ "$(cat "$MERGE_LOG")" = "$(printf '[%s]\n' "$URL" --disable-auto; echo --)" ]
    _stop_is 15 "required check not successful on head ${PR_HEAD:0:7}: $GBT (skipped); $RC_BAD_REMEDY"
    [[ "$output" == *"mergemr: auto-merge disabled: head ${PR_HEAD:0:7} $R12_REQ"* ]]
    _mrlog | grep -qxF "auto-merge disabled: head ${PR_HEAD:0:7} $R12_REQ"
    [ "$(_merges)" -eq 0 ]
}

@test "#1097 R12: auto-merge on with a pending required check turns auto-merge off, then rule 16 waits" {
    _req "[\"$GBT\"]"
    _view automerge=on rchecks="pending|$GBT"
    _run
    [ "$(cat "$MERGE_LOG")" = "$(printf '[%s]\n' "$URL" --disable-auto; echo --)" ]
    _wait_is 16 "CI PENDING: 1 of 2 checks still running on $URL (head ${PR_HEAD:0:7}): $GBT"
    [[ "$output" == *"mergemr: auto-merge disabled: head ${PR_HEAD:0:7} $R12_REQ"* ]]
}

@test "#1097 R12: auto-merge that cannot be turned off with a required check not successful stops" {
    _req "[\"$GBT\"]"
    _view automerge=on rchecks="pass|$GBT|SKIPPED"
    export MERGE_RC=1 STUB_MERGE_ERR="GraphQL: Pull request auto merge is not allowed"
    _run
    _stop_is 15 "head ${PR_HEAD:0:7} $R12_REQ; could not disable auto-merge: GraphQL: Pull request auto merge is not allowed; disable it on the forge, then run /devagent:unstuck; required checks at ${PR_HEAD:0:7}: $GBT: skipped"
    [ "$(_merges)" -eq 0 ]
}

@test "#1097 R12: a merge queue with a pending required check stops" {
    _req "[\"$GBT\"]"
    _view queue=true mergestate=BLOCKED rchecks="pending|$GBT"
    _run
    _stop_is 15 "head ${PR_HEAD:0:7} $R12_REQ, but the PR is in a merge queue; remove it from the queue on the forge, then run /devagent:unstuck; required checks at ${PR_HEAD:0:7}: $GBT: pending"
    [ ! -e "$MERGE_LOG" ]
    # the remedy: out of the queue, then unstuck; the check has succeeded meanwhile
    _view rchecks="pass|$GBT|SUCCESS"
    _unstuck
    _next_run_merges "$PR_HEAD"
}

@test "#1097 R12: a forwarded head that is not green keeps its own stop and names the required checks" {
    _req "[\"$GBT\"]"
    devagent_state_set "$STATE" verified_by forward
    _view queue=true mergestate=BLOCKED rchecks="pending|$GBT"
    _run
    _stop_is 17 "head ${PR_HEAD:0:7} was recorded by forward and merges only on green CI (pending), but the PR is in a merge queue; remove it from the queue on the forge, then run /devagent:unstuck; required checks at ${PR_HEAD:0:7}: $GBT: pending"
    [ ! -e "$MERGE_LOG" ]
}

# ---- #1097: CI NOT CHECKED (rule 20) ------------------------------------------------
# A project with required checks on a code backend that cannot report checks stops
# [!], whatever merge_mr says: nothing there can say a required check succeeded. The
# gitlab stub has no mr-checks (exit 2) until _checks serves one.

# _nc <why> [<names>]: rule 20's text. _nc_mark: the same where the step cannot read
# the PR's state, so the remedy also marks the row.
_nc() {
    printf '%s' "CI NOT CHECKED: $1; required check ${2:-$GBT} cannot be read on this code backend; check it by hand, merge the PR by hand, then run /devagent:unstuck"
}
_nc_mark() { printf '%s and mark this step [x] with /devagent:checklist-mark' "$(_nc "$@")"; }

# _mark_x: the remedy's last step where no run can see the hand merge.
_mark_x() {
    run bash "$DEVAGENT_ROOT/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" mergemr x
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
}

# _checks [<kind>|<name>[|<CONCLUSION>] ...]: the stub answers mr-checks from $MC_OUT:
# an open PR at $PR_HEAD with these check lines (the fields of _view's rchecks).
_checks() {
    local item kind name concl
    export MC_OUT="$STUB_DIR/checks.txt"
    {
        printf 'state\topen\nhead\t%s\n' "$PR_HEAD"
        for item in "$@"; do
            IFS='|' read -r kind name concl <<<"$item"
            if [ -n "$concl" ]; then printf '%s\t%s\t-\t%s\n' "$kind" "$name" "$concl"
            else printf '%s\t%s\t-\n' "$kind" "$name"; fi
        done
    } > "$MC_OUT"
}

# _custom: the project's code backend is the shipped scripts/code/custom.sh (exit 78
# on mr-state), behind a wrapper that counts the call.
_custom() {
    cat > "$DEVAGENT_TMP/fake-code/custom.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "\$STUB_DIR/calls"
exec "$DEVAGENT_ROOT/scripts/code/custom.sh" "\$@"
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/custom.sh"
    _set code_source.backend custom
}

@test "#1097 other backend: an open PR with a required check is [!] CI NOT CHECKED under both merge_mr values" {
    _gitlab
    _req "[\"$GBT\", \"lint\"]"
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run                                    # the gitlab stub has no mr-checks: exit 2
        _stop_is 20 "$(_nc "gitlab has no mr-checks" "$GBT, lint")"
        _unstuck
    done
    [ "$(_calls mr-state)" -eq 2 ]
    [ "$(_calls mr-checks)" -eq 2 ]
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 local backend: CI NOT CHECKED; the script is never asked for mr-checks" {
    cp "$DEVAGENT_TMP/fake-code/github.sh" "$DEVAGENT_TMP/fake-code/local.sh"
    _set code_source.backend local
    _req "[\"$GBT\"]"
    _run
    _stop_is 20 "$(_nc "local code backend")"
    [ "$(_calls mr-state)" -eq 1 ]
    [ "$(_calls mr-checks)" -eq 0 ]
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#1097 custom backend (mr-state exits 78) with a required check: CI NOT CHECKED" {
    _custom
    _req "[\"$GBT\"]"
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        _stop_is 20 "$(_nc_mark "custom has no mr-state")"
        _unstuck
    done
    [ "$(_calls mr-state)" -eq 2 ]
    [ "$(_calls mr-checks)" -eq 0 ]
    _gitlab                                     # an unknown verb (exit 2) is the same stop
    STUB_MRSTATE_RC=2 run "$MM" "$TEST_PROJECT" </dev/null
    _stop_is 20 "$(_nc_mark "gitlab has no mr-state")"
}

# inv: green before and after.
@test "#1097 custom backend (mr-state exits 78) with no key or an empty list: today's [?] cannot read PR state" {
    _custom
    _run
    _wait_is read "cannot read PR state on custom; merge by hand, then mark this step [x] with /devagent:checklist-mark"
    _req '[]'
    _run
    _wait_is read "cannot read PR state on custom; merge by hand, then mark this step [x] with /devagent:checklist-mark"
    [ "$(_calls mr-state)" -eq 2 ]
    [ "$(_calls mr-checks)" -eq 0 ]
}

# inv: green before and after. No CI read unless the PR is open.
@test "#1097 other backend: merged, closed and draft are unchanged" {
    _gitlab
    _req "[\"$GBT\"]"
    STUB_MRSTATE=draft run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is 5 "draft PR"
    STUB_MRSTATE=closed run "$MM" "$TEST_PROJECT" </dev/null
    _stop_is 4 "PR closed unmerged. To close out an abandoned PR, run /devagent:unstuck, then mark this step [-] with /devagent:checklist-mark"
    _unstuck
    STUB_MRSTATE=MERGED run "$MM" "$TEST_PROJECT" </dev/null
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    _mrlog | grep -qxF "PR $URL merged (merge commit -)"
    [ "$(_calls mr-checks)" -eq 0 ]
    [ "$(_calls mr-view)" -eq 0 ]
}

@test "#1097 other backend with mr-checks: [?] names each required check" {
    _gitlab
    _req "[\"$GBT\", \"lint\", \"docs\"]"
    _checks "pass|ci" "pass|$GBT|SUCCESS" "pass|lint|SKIPPED"
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        _run
        _wait_is 8 "waiting for merge (merge step supports github only); required checks at ${PR_HEAD:0:7}: $GBT: success; lint: skipped; docs: missing"
    done
    [ "$(_calls mr-checks)" -eq 2 ]
    [ "$(_calls mr-view)" -eq 0 ]
    [ ! -e "$MERGE_LOG" ]
}

# inv: green before and after. Without the key nothing reads CI on another backend.
@test "#1097 other backend with mr-checks and no key: today's [?], no CI read" {
    _gitlab
    _checks "pass|$GBT|SKIPPED"
    _run
    _wait_is 8 "waiting for merge (merge step supports github only)"
    [[ "$output" != *"required checks"* ]]
    [ "$(_calls mr-checks)" -eq 0 ]
}

@test "#1097 other backend: a failed mr-checks read waits, no STUCK" {
    _gitlab
    _req "[\"$GBT\"]"
    _checks "pass|$GBT|SUCCESS"
    STUB_CHECKS_RC=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read required checks on $URL: stub: mr-checks failed"
    STUB_CHECKS_SLEEP=10 DEVAGENT_CI_READ_SECS=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read required checks on $URL: timed out after 1s"
    printf 'state\topen\n' > "$MC_OUT"          # no head line: not an mr-checks reply
    _run
    _wait_is read "could not read required checks on $URL: unrecognised mr-checks output"
    [ "$(_calls mr-checks)" -eq 3 ]
}

@test "#1097 a github backend without mr-view stops CI NOT CHECKED" {
    _req "[\"$GBT\"]"
    for mm in true false; do
        _setb permissions.merge_mr "$mm"
        for rc in 78 2; do
            STUB_VIEW_RC=$rc run "$MM" "$TEST_PROJECT" </dev/null
            _stop_is 20 "$(_nc_mark "github has no mr-view")"
            _unstuck
        done
    done
    [ ! -e "$MERGE_LOG" ]
}

# inv: green before and after. Only a missing verb is rule 20: a read that failed
# another way still waits, with a required check too.
@test "#1097 a github backend without mr-view and no key: today's read wait" {
    STUB_VIEW_RC=78 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read PR $URL: github has no mr-view"
    _req "[\"$GBT\"]"
    STUB_VIEW_RC=1 run "$MM" "$TEST_PROJECT" </dev/null
    _wait_is read "could not read PR $URL: HTTP 502: bad gateway"
    [ ! -e "$MERGE_LOG" ]
}

@test "#1097 remedy: merge by hand, unstuck; the next run is [x]; unstuck alone stops again" {
    _gitlab
    _req "[\"$GBT\"]"
    _run
    _stop_is 20 "$(_nc "gitlab has no mr-checks")"
    _preship                                    # operator-only: a passing preship leaves it
    assert_step "$CL" 20 '!' mergemr
    [ "$(_reason)" = "mergemr rule 20: $(_nc "gitlab has no mr-checks")" ]
    _unstuck
    _run                                        # unstuck alone: the PR is still open
    _stop_is 20 "$(_nc "gitlab has no mr-checks")"
    _unstuck
    STUB_MRSTATE=MERGED run "$MM" "$TEST_PROJECT" </dev/null    # merged by hand
    echo "status=$status output=$output" >&2
    [ "$status" -eq 0 ]
    assert_step "$CL" 20 x mergemr
    [ ! -e "$ISSUE_DIR/STUCK" ]
    _mrlog | grep -qxF "PR $URL merged (merge commit -)"
    [ "$(_transitions)" -eq 1 ]
}

@test "#1097 remedy where the PR cannot be read: merge by hand, unstuck, mark [x]; unstuck alone stops again" {
    _custom
    _req "[\"$GBT\"]"
    _run
    _stop_is 20 "$(_nc_mark "custom has no mr-state")"
    _unstuck
    _run                                        # merged by hand or not, no run can tell
    _stop_is 20 "$(_nc_mark "custom has no mr-state")"
    _unstuck
    _mark_x
    # a github backend without mr-view: the same remedy
    _set code_source.backend github
    mark_step "$CL" 20 ' '
    STUB_VIEW_RC=78 run "$MM" "$TEST_PROJECT" </dev/null
    _stop_is 20 "$(_nc_mark "github has no mr-view")"
    _unstuck
    _mark_x
}
