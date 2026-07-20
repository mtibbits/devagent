#!/usr/bin/env bats
# #536: the throwaway spike worktree lifecycle. The worktree must be cut at the
# RESOLVED baseline (never HEAD, never the issue branch — the #72 mis-base hazard),
# and BOTH the worktree and its temp branch must be gone after teardown, including
# on the failure path.
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

_wt_root() { printf '%s\n' "$SOURCE_DIR-wt"; }

@test "spike create cuts the worktree at the resolved default_baseline, not HEAD (#72)" {
    # Point default_baseline at a RESOLVABLE local ref (the fixture has no remote,
    # so the stock origin/main would take the documented HEAD-fallback path and the
    # test would prove nothing), then move HEAD away so a fallback IS visible.
    python3 - "$HOME/.claude/devagent/config.toml" <<'PY2'
import sys
path = sys.argv[1]
t = open(path).read()
# REPLACE (never append — a duplicate key is a tomllib error, Issue-116)
assert 'default_baseline = "origin/main"' in t
open(path, 'w').write(t.replace('default_baseline = "origin/main"', 'default_baseline = "main"', 1))
PY2
    local base_sha; base_sha="$( cd "$SOURCE_DIR" && git rev-parse main )"
    ( cd "$SOURCE_DIR" && git checkout -q -b decoy && touch DECOY && git add DECOY \
      && git commit -q -m decoy )
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    local wt; wt="$(_wt_root)/issue-1-spike"
    [ -e "$wt" ]
    # AT the resolved baseline (main), NOT the moved HEAD (decoy)
    [ "$( cd "$wt" && git rev-parse HEAD )" = "$base_sha" ]
    [ ! -e "$wt/DECOY" ]
}

@test "spike create honors the per-issue .devagent-baseline override (#162/#72)" {
    ( cd "$SOURCE_DIR" && git checkout -q -b dev/all-prs && touch HARNESS && git add HARNESS \
      && git commit -q -m harness && git checkout -q main )
    local ovr_sha; ovr_sha="$( cd "$SOURCE_DIR" && git rev-parse dev/all-prs )"
    echo "dev/all-prs" > "$DEVDOC_DIR/Issue-1/.devagent-baseline"
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$( cd "$(_wt_root)/issue-1-spike" && git rev-parse HEAD )" = "$ovr_sha" ]
    [ -e "$(_wt_root)/issue-1-spike/HARNESS" ]   # really the override's tree
}

@test "spike create records spike_worktree_path; teardown clears it and destroys both (#536)" {
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -q "spike_worktree_path *= *\"$(_wt_root)/issue-1-spike\"" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    ( cd "$SOURCE_DIR" && git show-ref --verify --quiet refs/heads/spike/1 )

    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -e "$(_wt_root)/issue-1-spike" ]                                   # worktree gone
    run bash -c "cd '$SOURCE_DIR' && git show-ref --verify --quiet refs/heads/spike/1"
    [ "$status" -ne 0 ]                                                     # branch gone
    grep -q 'spike_worktree_path *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

@test "teardown destroys a worktree that has UNCOMMITTED spike edits (--force path)" {
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    # a spike by definition dirties its tree; plain `worktree remove` refuses this
    echo scratch > "$(_wt_root)/issue-1-spike/experiment.txt"
    echo more >> "$(_wt_root)/issue-1-spike/experiment.txt"
    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -e "$(_wt_root)/issue-1-spike" ]
}

@test "teardown destroys a worktree whose spike COMMITTED (branch -D path)" {
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    ( cd "$(_wt_root)/issue-1-spike" && echo x > probe.txt && git add probe.txt \
      && git commit -q -m "spike probe" )
    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ ! -e "$(_wt_root)/issue-1-spike" ]
    run bash -c "cd '$SOURCE_DIR' && git show-ref --verify --quiet refs/heads/spike/1"
    [ "$status" -ne 0 ]   # unmerged branch still deleted
}

@test "teardown is idempotent (second run is a clean no-op)" {
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
}

@test "create RECLAIMS a stale worktree/branch from a crashed run (re-runnable)" {
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    # simulate a crash: the worktree + branch survive, no teardown ran
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]                       # must NOT die "already exists"
    [ -e "$(_wt_root)/issue-1-spike" ]
}

@test "Issue-N and Issue-Fork-N get DISTINCT spike worktrees and branches (#422/#332)" {
    mkdir -p "$DEVDOC_DIR/Issue-Fork-1"
    cp "$DEVDOC_DIR/Issue-1/checklist.md" "$DEVDOC_DIR/Issue-Fork-1/checklist.md" 2>/dev/null || true
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-Fork-1
    [ "$status" -eq 0 ]                       # born-red: the bare-numeric form died "already exists"
    [ -e "$(_wt_root)/issue-1-spike" ]
    [ -e "$(_wt_root)/issue-fork-1-spike" ]
    ( cd "$SOURCE_DIR" && git show-ref --verify --quiet refs/heads/spike/1 )
    ( cd "$SOURCE_DIR" && git show-ref --verify --quiet refs/heads/spike/fork-1 )
}

# ---- Task 2: template row + flow position (SPLIT assertions — never `a && b`, #535) ----
@test "checklist-standard and checklist-perf carry [-] 23. spike between rows 1 and 2 (#536)" {
    local t d r sc
    for t in checklist-standard checklist-perf; do
        run grep -qE '^- \[-\] 23\. spike$' "$DEVAGENT_ROOT/templates/$t.md"
        [ "$status" -eq 0 ]
        d="$(grep -nE '^- \[ \]  1\. draft$'  "$DEVAGENT_ROOT/templates/$t.md" | cut -d: -f1)"
        r="$(grep -nE '^- \[-\] 23\. spike$'  "$DEVAGENT_ROOT/templates/$t.md" | cut -d: -f1)"
        sc="$(grep -nE '^- \[ \]  2\. scope$' "$DEVAGENT_ROOT/templates/$t.md" | cut -d: -f1)"
        [ "$d" -lt "$r" ]  || { echo "$t: spike row not after draft"; false; }
        [ "$r" -lt "$sc" ] || { echo "$t: spike row not before scope"; false; }
    done
}

# ---- Task 4/5/6/7 contract greps ----
@test "commands/spike.md: verdict schema, evidence, never-product, revise routing (#536)" {
    local f="$DEVAGENT_ROOT/commands/spike.md"
    grep -q 'VERIFIED' "$f"; grep -q 'FALSIFIED' "$f"; grep -q 'INCONCLUSIVE' "$f"
    grep -qi 'evidence' "$f"
    grep -qi 'never product\|never a product\|evidence, never product' "$f"
    grep -q 'revise' "$f"
    grep -q 'Step 23' "$f"
    # it authors spike.md, so Write must be granted (the #535 review lesson)
    grep -qE '^allowed-tools:.*\bWrite\b' "$f"
    # `(none)` unknowns is a legitimate outcome, not a finding
    grep -q '(none)' "$f"
}

@test "imPlan template + draft.md carry the Load-bearing unknowns declare contract (#536)" {
    grep -q '## Load-bearing unknowns' "$DEVAGENT_ROOT/templates/imPlan_template.md"
    grep -qE 'U<N> \(Task <M>\)|U1 \(Task N\)' "$DEVAGENT_ROOT/templates/imPlan_template.md"
    grep -q 'Load-bearing unknowns' "$DEVAGENT_ROOT/commands/draft.md"
    grep -qi 'cheapest probe' "$DEVAGENT_ROOT/commands/draft.md"
}

@test "the spike tripwire AND its dispatch packaging exist in ALL THREE homes (#536 B5/#286)" {
    # the tripwire item itself
    grep -q 'Spike tripwire' "$DEVAGENT_ROOT/skills/core-improve/SKILL.md"
    # packaging — a checklist item the checker never RECEIVES is a dead tripwire.
    # commands/improve.md is the home that BUILDS the dispatch prompt.
    local h
    for h in "$DEVAGENT_ROOT/commands/improve.md" \
             "$DEVAGENT_ROOT/agents/plan-improver.md" \
             "$DEVAGENT_ROOT/skills/core-improve/SKILL.md"; do
        grep -q 'Load-bearing unknowns' "$h" || { echo "missing unknowns in $h"; false; }
        grep -q 'spike.md' "$h"              || { echo "missing spike.md in $h"; false; }
        # the tripwire GATES on row 23's glyph, so checklist.md must reach the checker
        # too — a sweep that pins only the payload passes while the GATE input is
        # missing, which is #286 one level down (#536 redmr MAJOR).
        grep -q 'checklist.md' "$h"          || { echo "missing checklist.md (the gate input) in $h"; false; }
    done
}

@test "spec §6.3 carries row 23 and the 0–23 numbering (#536, #435 spec-touch)" {
    local f="$DEVAGENT_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
    grep -q '/devagent:spike' "$f"
    grep -q 'Numbered 0–23' "$f"
    grep -q 'spike_worktree_path' "$f"
}

@test "all 6 issue/epic templates document spike: required in prose (no live example, #537)" {
    local f
    for f in "$DEVAGENT_ROOT"/templates/issue_template-*.md "$DEVAGENT_ROOT/templates/epic_template.md"; do
        grep -q 'spike: required' "$f" || { echo "missing spike key in $f"; false; }
        grep -q 'No live example here on purpose' "$f" || { echo "lost #537 discipline in $f"; false; }
    done
}

# ---- #536 review BLOCKING-1: a destroy that only ATTEMPTED must not report success ----
@test "teardown FAILS loudly and KEEPS state when the worktree cannot be destroyed" {
    "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    local wt; wt="$(_wt_root)/issue-1-spike"
    # sabotage: break the worktree link so `git worktree remove` cannot succeed
    rm -rf "$wt/.git" && mkdir -p "$wt/.git"
    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]                                  # must NOT claim success
    echo "$output" | grep -qi 'teardown FAILED'
    # the pointer to the surviving orphan must SURVIVE, not be erased
    grep -q "spike_worktree_path *= *\"$wt\"" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}

# ---- #536 review BLOCKING-2: the partial-setup guard must actually fire ----
@test "a failure AFTER worktree add leaves no worktree and no branch (partial-setup guard)" {
    run env DEVAGENT_SPIKE_FAIL_AFTER_ADD=1 \
        "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    [ ! -e "$(_wt_root)/issue-1-spike" ]                 # worktree cleaned up
    run bash -c "cd '$SOURCE_DIR' && git show-ref --verify --quiet refs/heads/spike/1"
    [ "$status" -ne 0 ]                                  # temp branch cleaned up
    # and no stale pointer was recorded
    run grep -q "spike_worktree_path *= *\"$(_wt_root)/issue-1-spike\"" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}

# ---- #536 review non-blocking: never force-delete a branch this step did not create ----
@test "create REFUSES a pre-existing spike/<id> branch that has no recorded worktree" {
    ( cd "$SOURCE_DIR" && git branch spike/1 )           # hand-made, carries real work
    run "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'refusing to delete a branch this step did not create'
    ( cd "$SOURCE_DIR" && git show-ref --verify --quiet refs/heads/spike/1 )  # survived
}

# ---- #536 redmr BLOCKING: teardown must NOT delete a branch it does not own ----
@test "teardown with NOTHING recorded leaves a same-named branch untouched" {
    ( cd "$SOURCE_DIR" && git branch spike/1 )      # a human's branch, unmerged work
    run "$DEVAGENT_ROOT/scripts/spike.sh" teardown "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'nothing recorded'
    ( cd "$SOURCE_DIR" && git show-ref --verify --quiet refs/heads/spike/1 )   # SURVIVES
}

# ---- #536 redmr MAJOR: the SIGNAL half of the partial-setup guard ----
@test "SIGTERM after worktree add destroys the worktree and branch and exits non-zero" {
    DEVAGENT_SPIKE_SLEEP_AFTER_ADD=30 \
      "$DEVAGENT_ROOT/scripts/spike.sh" create "$TEST_PROJECT" Issue-1 &
    local pid=$!
    # wait for the worktree to actually exist, then signal
    local i=0
    while [ ! -e "$(_wt_root)/issue-1-spike" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    [ -e "$(_wt_root)/issue-1-spike" ]
    kill -TERM "$pid"
    local rc=0; wait "$pid" || rc=$?
    # The EXIT trap alone can satisfy "worktree gone", so worktree/branch assertions
    # CANNOT discriminate the signal handler. The exit CODE can, and only this value:
    #   1   = _spike_abort ran and exited explicitly (correct)
    #   143 = 128+SIGTERM, bash died with no signal trap at all
    #   0   = handler ran but did NOT exit, so the script RESUMED and "succeeded"
    #         (the exact bash-resumes-after-handler bug this guard exists for)
    [ "$rc" -eq 1 ] || { echo "expected exit 1 from _spike_abort, got $rc"; false; }
    [ ! -e "$(_wt_root)/issue-1-spike" ]                                    # worktree gone
    run bash -c "cd '$SOURCE_DIR' && git show-ref --verify --quiet refs/heads/spike/1"
    [ "$status" -ne 0 ]                                                      # branch gone
    # ...and no pointer to a nonexistent tree was recorded on the way out
    run grep -q "spike_worktree_path *= *\"$(_wt_root)/issue-1-spike\"" \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    [ "$status" -ne 0 ]
}
