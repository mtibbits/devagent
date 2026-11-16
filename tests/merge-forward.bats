#!/usr/bin/env bats
# #1125: `preship-verified-head.sh forward` re-records verified_head after a
# merge-forward that only re-applies git's own merge of the base (plus keep-both
# in a declared append-only file), marked verified_by = forward. Every refusal
# exits 1, names its condition, and writes nothing. Real throwaway git repos, as
# rebaseline.bats: a bare `origin`, an upstream working clone that advances it,
# and the test project's SOURCE_DIR on the issue branch.
load 'helpers/common'

RECIPE='re-run run-suite.sh and evidence-stamp.sh (review.md 6a), push, then run /devagent:preship'

setup() {
    devagent_test_setup
    export ORIGIN="$DEVAGENT_TMP/origin.git" UPWC="$DEVAGENT_TMP/upstream-wc"
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    export CL="$ISSUE_DIR/checklist.md"
    export PVH="$DEVAGENT_ROOT/scripts/preship-verified-head.sh"
    git -c init.defaultBranch=main init -q --bare "$ORIGIN"
    ( cd "$SOURCE_DIR" \
      && printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n- old\n' > CHANGELOG.md \
      && git add CHANGELOG.md && git commit -q -m changelog \
      && git remote add origin "$ORIGIN" \
      && git push -q origin main \
      && git fetch -q origin \
      && git checkout -q -b feat/1-x \
      && echo f1 > f1.txt && git add f1.txt && git commit -q -m f1 )
    git clone -q -b main "$ORIGIN" "$UPWC"
    git -C "$UPWC" config user.email up@example.com
    git -C "$UPWC" config user.name Upstream
    C0="$(git -C "$SOURCE_DIR" rev-parse main)"
    VH="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    devagent_state_set "$STATE" branch "feat/1-x"
    devagent_state_set "$STATE" baseline_sha "$C0"
    devagent_state_set "$STATE" verified_head "$VH"
    printf '# Issue-1 MR\n\nA change.\n' > "$ISSUE_DIR/mr.md"
}
teardown() { devagent_test_teardown; }

# _mf_config <verify|-> <list-literal|->: append the [project.<p>.merge_forward] table.
_mf_config() {
    {
        printf '\n[project.%s.merge_forward]\n' "$TEST_PROJECT"
        [ "$1" = - ] || printf 'verify = %s\n' "$1"
        [ "$2" = - ] || printf 'append_only = %s\n' "$2"
    } >> "$HOME/.claude/devagent/config.toml"
}

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
_snapshot() { cp "$STATE" "$DEVAGENT_TMP/state.before"; cp "$CL" "$DEVAGENT_TMP/cl.before"; }
_untouched() { cmp -s "$STATE" "$DEVAGENT_TMP/state.before" && cmp -s "$CL" "$DEVAGENT_TMP/cl.before"; }

# _upstream_commit <name>: advance origin's main by one new file; print its SHA.
_upstream_commit() {
    ( cd "$UPWC" && echo "$1" > "$1.txt" && git add "$1.txt" && git commit -q -m "$1" \
      && git push -q origin main && git rev-parse HEAD )
}

# _changelog_entry <dir> <entry>: add `- <entry>` right under ## [Unreleased].
_changelog_entry() {
    sed -i "/^## \[Unreleased\]\$/a - $2" "$1/CHANGELOG.md"
}

# _upstream_changelog <entry>: origin's main adds a changelog entry; print its SHA.
_upstream_changelog() {
    _changelog_entry "$UPWC" "$1"
    ( cd "$UPWC" && git commit -q -am "$1" && git push -q origin main && git rev-parse HEAD )
}

# _branch_changelog <entry>: the issue branch adds a changelog entry (and is re-verified).
_branch_changelog() {
    _changelog_entry "$SOURCE_DIR" "$1"
    git -C "$SOURCE_DIR" commit -q -am "$1"
    VH="$(_head)"
    devagent_state_set "$STATE" verified_head "$VH"
}

# _merge_forward: merge the current origin/main into the issue branch (clean).
_merge_forward() {
    ( cd "$SOURCE_DIR" && git fetch -q origin && git merge -q --no-edit origin/main )
}

# _merge_forward_keep_both [order]: merge origin/main, resolve every conflicted
# file's hunks by keeping both sides (ours first, or theirs first), commit.
_merge_forward_keep_both() {
    ( cd "$SOURCE_DIR" && git fetch -q origin \
      && { git merge -q --no-edit origin/main >/dev/null 2>&1 || true; } \
      && git diff --name-only --diff-filter=U -z > "$DEVAGENT_TMP/unmerged" \
      && python3 - "${1:-ours}" "$DEVAGENT_TMP/unmerged" <<'PY'
import re, sys
pat = re.compile(r"<<<<<<< [^\n]*\n(.*?)(?:\|\|\|\|\|\|\| [^\n]*\n.*?)?=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
for p in open(sys.argv[2]).read().split("\0"):
    if not p:
        continue
    s = open(p).read()
    s = pat.sub((lambda m: m.group(1) + m.group(2)) if sys.argv[1] == "ours" else (lambda m: m.group(2) + m.group(1)), s)
    open(p, "w").write(s)
PY
    ) && git -C "$SOURCE_DIR" add -A && git -C "$SOURCE_DIR" commit -q --no-edit
}

# _merge_forward_resolved_as <text>: merge origin/main, write <text> as the
# resolved CHANGELOG.md, commit (the operator's hand resolution).
_merge_forward_resolved_as() {
    ( cd "$SOURCE_DIR" && git fetch -q origin \
      && { git merge -q --no-edit origin/main >/dev/null 2>&1 || true; } \
      && printf '%s' "$1" > CHANGELOG.md && git add CHANGELOG.md && git commit -q --no-edit )
}

_rebaseline() {
    run "$DEVAGENT_ROOT/scripts/rebaseline.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

# _fwd: run forward and echo its output for a failing test's log.
_fwd() {
    run "$PVH" forward "$TEST_PROJECT"
    echo "$output" >&2
}

_refused() {   # _refused <condition> <detail>
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: forward refused ($1): $2"* ]]
    _untouched
}

# ---- success -----------------------------------------------------------------

@test "#1125 clean merge-forward passes without append_only" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
    local h; h="$(_head)"
    [ "$(_key verified_head)" = "$h" ]
    [ "$(_key verified_by)" = forward ]
    [[ "$output" == *"forward: verified_head $h from ${VH:0:7} (git's merge of ${t:0:7}; no conflict)"* ]]
    [ "$(grep -cE "^- [0-9-]+ [0-9:]+  forward: verified_head $h from ${VH:0:7} \(git's merge of ${t:0:7}; no conflict\)$" "$CL")" -eq 1 ]
}

@test "#1125 clean merge-forward passes with append_only set" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    local t; t="$(_upstream_commit u1)"
    _merge_forward; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
    [ "$(_key verified_head)" = "$(_head)" ]
    [ "$(_key verified_by)" = forward ]
    [ "$(grep -c "forward: verified_head $(_head) from ${VH:0:7} (git's merge of ${t:0:7}; no conflict)" "$CL")" -eq 1 ]
}

@test "#1125 two stacked merges pass" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    _merge_forward
    local t; t="$(_upstream_commit u2)"
    _merge_forward; _rebaseline
    [ "$(_key baseline_sha)" = "$t" ]
    _fwd
    [ "$status" -eq 0 ]
    [ "$(_key verified_head)" = "$(_head)" ]
    [[ "$output" == *"from ${VH:0:7} (git's merge of ${t:0:7}; no conflict)"* ]]
}

@test "#1125 a short hand-set baseline_sha equal to T passes" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward
    devagent_state_set "$STATE" baseline_sha "${t:0:9}"
    _fwd
    [ "$status" -eq 0 ]
    [ "$(_key verified_by)" = forward ]
}

# ---- not git's merge ---------------------------------------------------------

@test "#1125 not git's merge: an extra line change refuses naming the path" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward
    echo extra >> "$SOURCE_DIR/f1.txt"
    git -C "$SOURCE_DIR" commit -q -a --amend --no-edit
    _rebaseline; _snapshot
    _fwd
    _refused merge "f1.txt differs from git's merge of ${VH:0:7} and ${t:0:7}"
}

@test "#1125 not git's merge: a mode change refuses naming the path" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward
    git -C "$SOURCE_DIR" update-index --chmod=+x f1.txt
    git -C "$SOURCE_DIR" commit -q --amend --no-edit
    git -C "$SOURCE_DIR" checkout -q -- f1.txt
    _rebaseline; _snapshot
    _fwd
    _refused merge "f1.txt differs from git's merge of ${VH:0:7} and ${t:0:7}"
}

@test "#1125 not git's merge: a binary change refuses naming the path" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward
    printf '\x00\x01\x02binary' > "$SOURCE_DIR/blob.bin"
    git -C "$SOURCE_DIR" add blob.bin
    git -C "$SOURCE_DIR" commit -q --amend --no-edit
    _rebaseline; _snapshot
    _fwd
    _refused merge "blob.bin differs from git's merge of ${VH:0:7} and ${t:0:7}"
}

# ---- shape -------------------------------------------------------------------

@test "#1125 shape: a commit after the merge refuses" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    echo f2 > "$SOURCE_DIR/f2.txt"
    git -C "$SOURCE_DIR" add f2.txt && git -C "$SOURCE_DIR" commit -q -m f2
    _snapshot
    _fwd
    _refused shape "$(_head | cut -c1-7) on HEAD's first-parent path is not a merge; $RECIPE"
}

@test "#1125 a forward refusal's remedy names run-suite.sh, evidence-stamp.sh, push and /devagent:preship" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    echo f2 > "$SOURCE_DIR/f2.txt"
    git -C "$SOURCE_DIR" add f2.txt && git -C "$SOURCE_DIR" commit -q -m f2
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *run-suite.sh*evidence-stamp.sh*push*/devagent:preship* ]]
}

@test "#1125 shape: a merge not chained to verified_head refuses" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward; _rebaseline
    # Another merge of the same two parents stands in as verified_head: HEAD's
    # first-parent path does not pass through it.
    local other
    other="$(git -C "$SOURCE_DIR" commit-tree -p "$VH" -p "$t" -m other "$(_head)^{tree}")"
    devagent_state_set "$STATE" verified_head "$other"
    _snapshot
    _fwd
    _refused shape "HEAD's first-parent path does not reach verified_head ${other:0:7}; $RECIPE"
}

@test "#1125 shape: a second parent not on the base refuses" {
    _mf_config '"ci"' -
    ( cd "$SOURCE_DIR" && git checkout -q -b side main && echo s > s.txt && git add s.txt \
      && git commit -q -m side && git checkout -q feat/1-x && git merge -q --no-edit side )
    local side c tip
    side="$(git -C "$SOURCE_DIR" rev-parse side)"; c="$(_head)"
    tip="$(git -C "$SOURCE_DIR" rev-parse origin/main)"
    _snapshot
    _fwd
    _refused shape "second parent ${side:0:7} of ${c:0:7} is not on origin/main (${tip:0:7})"
}

@test "#1125 shape: rebaseline.sh not run refuses" {
    _mf_config '"ci"' -
    local t; t="$(_upstream_commit u1)"
    _merge_forward
    _snapshot
    _fwd
    _refused shape "baseline_sha ${C0:0:7} is not ${t:0:7}, the base commit HEAD's last merge brought in; run rebaseline.sh"
}

@test "#1125 enabled: verify absent refuses" {
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    _snapshot
    _fwd
    _refused enabled "[project.$TEST_PROJECT.merge_forward] verify is not \"ci\" (absent); $RECIPE"
}

@test "#1125 enabled: verify = \"preship\" refuses" {
    _mf_config '"preship"' -
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    _snapshot
    _fwd
    _refused enabled "[project.$TEST_PROJECT.merge_forward] verify is not \"ci\" (preship); $RECIPE"
}

@test "#1125 shape: HEAD equals verified_head refuses" {
    _mf_config '"ci"' -
    _snapshot
    _fwd
    _refused shape "HEAD is verified_head ${VH:0:7}; there is no merge-forward to verify"
}

@test "#1125 shape: an octopus merge refuses" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    ( cd "$SOURCE_DIR" && git fetch -q origin \
      && git checkout -q -b side main && echo s > s.txt && git add s.txt && git commit -q -m side \
      && git checkout -q feat/1-x && git merge -q --no-edit origin/main side )
    _snapshot
    _fwd
    _refused shape "$(_head | cut -c1-7) has 3 parents; only two-parent merges are forwarded"
}

# ---- recorded ----------------------------------------------------------------

@test "#1125 recorded: no verified_head refuses" {
    _mf_config '"ci"' -
    devagent_state_set "$STATE" verified_head ""
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    _snapshot
    _fwd
    _refused recorded "no verified_head recorded; $RECIPE"
}

@test "#1125 recorded: a dirty tree refuses" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    echo dirty >> "$SOURCE_DIR/f1.txt"
    _snapshot
    _fwd
    _refused recorded "uncommitted changes in $SOURCE_DIR; commit or discard them first"
}

@test "#1125 recorded: off-branch refuses" {
    _mf_config '"ci"' -
    git -C "$SOURCE_DIR" checkout -q main
    _snapshot
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"preship-verified-head: HEAD is on main, not the issue branch feat/1-x"* ]]
    _untouched
}

# ---- bad config at use -------------------------------------------------------

@test "#1125 bad config at use: append_only as a string dies" {
    _mf_config '"ci"' '"CHANGELOG.md"'
    _snapshot
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.append_only must be an array of strings, e.g. append_only = [\"CHANGELOG.md\"]; fix [project.$TEST_PROJECT.merge_forward] append_only"* ]]
    _untouched
}

@test "#1125 bad config at use: an absolute entry dies" {
    _mf_config '"ci"' '["/CHANGELOG.md"]'
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.append_only entry '/CHANGELOG.md' is not an exact repo-relative file path"*"fix [project.$TEST_PROJECT.merge_forward] append_only"* ]]
}

@test "#1125 bad config at use: a .. entry dies" {
    _mf_config '"ci"' '["../CHANGELOG.md"]'
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.append_only entry '../CHANGELOG.md' is not an exact repo-relative file path"* ]]
}

@test "#1125 bad config at use: a glob entry dies" {
    _mf_config '"ci"' '["CHANGE?.md"]'
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.append_only entry 'CHANGE?.md' is not an exact repo-relative file path"* ]]
}

@test "#1125 bad config at use: verify = \"maybe\" dies" {
    _mf_config '"maybe"' -
    _fwd
    [ "$status" -eq 1 ]
    [[ "$output" == *"merge_forward.verify must be \"ci\" or \"preship\" (got 'maybe'); fix [project.$TEST_PROJECT.merge_forward] verify"* ]]
}

# ---- conflicts, drivers, append-only hunks, merge gate (Task 5) ---------------

@test "#1125 changelog-only conflict: keep both, rebaseline, forward exits 0" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    local t; t="$(_upstream_changelog "theirs entry")"
    _merge_forward_keep_both; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
    local h; h="$(_head)"
    [ "$(_key verified_head)" = "$h" ]
    [ "$(_key verified_by)" = forward ]
    [ "$(grep -c "forward: verified_head $h from ${VH:0:7} (git's merge of ${t:0:7}; both sides kept in CHANGELOG.md)\$" "$CL")" -eq 1 ]
}

@test "#1125 changelog-only conflict: theirs first passes too" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both theirs; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
}

@test "#1125 keep-both outside append_only refuses naming the path" {
    _mf_config '"ci"' -
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline; _snapshot
    _fwd
    _refused merge "CHANGELOG.md conflicts in git's merge and is not in merge_forward.append_only"
}

@test "#1125 merge=union in .gitattributes refuses naming the attribute" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    echo 'CHANGELOG.md merge=union' > "$SOURCE_DIR/.gitattributes"
    git -C "$SOURCE_DIR" add .gitattributes && git -C "$SOURCE_DIR" commit -q -m attrs
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward; _rebaseline; _snapshot      # union: git merges it with no conflict
    _fwd
    _refused merge "CHANGELOG.md has merge=union (git check-attr); a merge driver hides conflicts from git's merge"
}

@test "#1125 merge=union in .git/info/attributes refuses naming the attribute" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline
    echo 'CHANGELOG.md merge=union' >> "$SOURCE_DIR/.git/info/attributes"
    _snapshot
    _fwd
    _refused merge "CHANGELOG.md has merge=union (git check-attr); a merge driver hides conflicts from git's merge"
}

@test "#1125 merge=union in an untracked worktree .gitattributes refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline
    echo 'CHANGELOG.md merge=union' > "$SOURCE_DIR/.gitattributes"
    _snapshot
    _fwd
    _refused merge "CHANGELOG.md has merge=union (git check-attr); a merge driver hides conflicts from git's merge"
}

@test "#1125 merge=union on a path not in the tree does not refuse (control)" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline
    echo 'other.md merge=union' > "$SOURCE_DIR/.gitattributes"
    _fwd
    [ "$status" -eq 0 ]
}

@test "#1125 a binary-macro path does not refuse" {
    _mf_config '"ci"' -
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline
    echo 'f1.txt binary' >> "$SOURCE_DIR/.git/info/attributes"
    _fwd
    [ "$status" -eq 0 ]
}

@test "#1125 two stacked merges each conflicting in CHANGELOG.md pass" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs one" >/dev/null
    _merge_forward_keep_both
    local t; t="$(_upstream_changelog "theirs two")"
    _merge_forward_keep_both; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
    [[ "$output" == *"(git's merge of ${t:0:7}; both sides kept in CHANGELOG.md)"* ]]
}

@test "#1125 two conflicted append-only paths pass and log 'both sides kept in <p1>, <p2>'" {
    _mf_config '"ci"' '["NEWS.md", "CHANGELOG.md"]'
    # Both files exist on the base and in verified_head.
    cp "$UPWC/CHANGELOG.md" "$UPWC/NEWS.md"
    ( cd "$UPWC" && git add NEWS.md && git commit -q -m news && git push -q origin main )
    _merge_forward
    VH="$(_head)"; devagent_state_set "$STATE" verified_head "$VH"
    _changelog_entry "$SOURCE_DIR" "ours entry"; cp "$SOURCE_DIR/CHANGELOG.md" "$SOURCE_DIR/NEWS.md"
    git -C "$SOURCE_DIR" commit -q -am ours
    VH="$(_head)"; devagent_state_set "$STATE" verified_head "$VH"
    _changelog_entry "$UPWC" "theirs entry"; cp "$UPWC/CHANGELOG.md" "$UPWC/NEWS.md"
    local t; t="$( cd "$UPWC" && git commit -q -am theirs && git push -q origin main && git rev-parse HEAD )"
    _merge_forward_keep_both; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
    [[ "$output" == *"(git's merge of ${t:0:7}; both sides kept in CHANGELOG.md, NEWS.md)"* ]]
}

@test "#1125 a crashing checker refuses as checker failed" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline; _snapshot
    printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$DEVAGENT_TMP/crash.py"
    DEVAGENT_MF_HUNKS="$DEVAGENT_TMP/crash.py" run "$PVH" forward "$TEST_PROJECT"
    echo "$output" >&2
    _refused append-only "CHANGELOG.md: checker failed (exit 1)"
}

@test "#1125 a checker that refuses with no reason refuses as checker failed" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline; _snapshot
    printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' > "$DEVAGENT_TMP/mute.py"
    DEVAGENT_MF_HUNKS="$DEVAGENT_TMP/mute.py" run "$PVH" forward "$TEST_PROJECT"
    echo "$output" >&2
    _refused append-only "CHANGELOG.md: checker failed (exit 3)"
}

# Bad resolutions, through forward. The branch adds two entries, the base one.
_two_and_one() {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _changelog_entry "$SOURCE_DIR" "ours b"; _changelog_entry "$SOURCE_DIR" "ours a"
    git -C "$SOURCE_DIR" commit -q -am ours
    VH="$(_head)"; devagent_state_set "$STATE" verified_head "$VH"
    _upstream_changelog "theirs" >/dev/null
}
_cl() { printf '# Changelog\n\n## [Unreleased]\n'; printf '%s\n' "$@"; printf '\n## [1.0.0]\n- old\n'; }

@test "#1125 bad resolution: drops a line refuses" {
    _two_and_one
    _merge_forward_resolved_as "$(_cl '- ours a' '- theirs')"$'\n'; _rebaseline; _snapshot
    _fwd
    _refused append-only "CHANGELOG.md: hunk 1 is not both sides' lines as two contiguous runs"
}

@test "#1125 bad resolution: adds a line refuses" {
    _two_and_one
    _merge_forward_resolved_as "$(_cl '- ours a' '- ours b' '- extra' '- theirs')"$'\n'; _rebaseline; _snapshot
    _fwd
    _refused append-only "CHANGELOG.md: hunk 1 is not both sides' lines as two contiguous runs"
}

@test "#1125 bad resolution: interleaves two multi-line entries refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _changelog_entry "$SOURCE_DIR" "  ours detail"; _changelog_entry "$SOURCE_DIR" "ours entry"
    git -C "$SOURCE_DIR" commit -q -am ours
    VH="$(_head)"; devagent_state_set "$STATE" verified_head "$VH"
    _changelog_entry "$UPWC" "  theirs detail"; _changelog_entry "$UPWC" "theirs entry"
    ( cd "$UPWC" && git commit -q -am theirs && git push -q origin main )
    _merge_forward_resolved_as "$(_cl '- ours entry' '- theirs entry' '-   ours detail' '-   theirs detail')"$'\n'
    _rebaseline; _snapshot
    _fwd
    _refused append-only "CHANGELOG.md: hunk 1 is not both sides' lines as two contiguous runs"
}

@test "#1125 bad resolution: the branch entry under a release heading the base inserted refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _changelog_entry "$UPWC" "theirs entry"
    sed -i 's/^- theirs entry$/## [1.1.0]\n- theirs entry/' "$UPWC/CHANGELOG.md"
    ( cd "$UPWC" && git commit -q -am release && git push -q origin main )
    _merge_forward_resolved_as "$(_cl '## [1.1.0]' '- theirs entry' '- ours entry')"$'\n'
    _rebaseline; _snapshot
    _fwd
    _refused append-only "CHANGELOG.md: hunk 1: the branch's lines are not under ## [Unreleased]"
}

@test "#1125 bad resolution: a non-empty base section (base edited the adjacent entry) refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    sed -i 's/^## \[1.0.0\]$/&\n- ours entry/' "$SOURCE_DIR/CHANGELOG.md"
    git -C "$SOURCE_DIR" commit -q -am ours
    VH="$(_head)"; devagent_state_set "$STATE" verified_head "$VH"
    sed -i 's/^- old$/- old, fixed/' "$UPWC/CHANGELOG.md"
    ( cd "$UPWC" && git commit -q -am fix && git push -q origin main )
    _merge_forward_resolved_as $'# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n- ours entry\n- old, fixed\n'
    _rebaseline; _snapshot
    _fwd
    _refused append-only "CHANGELOG.md: hunk 1 has a non-empty base section"
}

@test "#1125 a resolution that differs only in blank lines inside the hunk passes" {
    _two_and_one
    _merge_forward_resolved_as "$(_cl '' '- ours a' '- ours b' '' '- theirs')"$'\n'; _rebaseline
    _fwd
    [ "$status" -eq 0 ]
}

@test "#1125 merge gate in mr.md refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    printf '# Issue-1 MR\n\n**Merge gate:** the operator flips a flag first.\n' > "$ISSUE_DIR/mr.md"
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both; _rebaseline; _snapshot
    _fwd
    _refused "merge gate" "$ISSUE_DIR/mr.md line 3 mentions a merge gate; head-tied evidence needs /devagent:preship"
}

@test "#1125 missing mr.md refuses" {
    _mf_config '"ci"' -
    rm "$ISSUE_DIR/mr.md"
    _upstream_commit u1 >/dev/null
    _merge_forward; _rebaseline; _snapshot
    _fwd
    _refused "merge gate" "cannot read $ISSUE_DIR/mr.md; cannot tell whether the MR carries a merge gate"
}

@test "#1125 a conflicted append-only path whose mode changed refuses" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    _upstream_changelog "theirs entry" >/dev/null
    _merge_forward_keep_both
    git -C "$SOURCE_DIR" update-index --chmod=+x CHANGELOG.md
    git -C "$SOURCE_DIR" commit -q --amend --no-edit
    git -C "$SOURCE_DIR" checkout -q -- CHANGELOG.md
    _rebaseline; _snapshot
    _fwd
    _refused merge "CHANGELOG.md changes mode"
}

@test "#1125 a modify/delete conflict on an append-only path refuses as not merged as text" {
    _mf_config '"ci"' '["CHANGELOG.md"]'
    _branch_changelog "ours entry"
    ( cd "$UPWC" && git rm -q CHANGELOG.md && git commit -q -m drop && git push -q origin main )
    ( cd "$SOURCE_DIR" && git fetch -q origin \
      && { git merge -q --no-edit origin/main >/dev/null 2>&1 || true; } \
      && git add CHANGELOG.md && git commit -q --no-edit )
    _rebaseline; _snapshot
    _fwd
    _refused merge "CHANGELOG.md has a conflict git did not merge as text"
}
