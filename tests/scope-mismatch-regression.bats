#!/usr/bin/env bats
# #572 AC2/AC3/AC6: the two-project regression fixture. Pointer on projB,
# work (cwd) in projA (testproj), DEVAGENT_ACTIVE_* unset.
#
# Leg 1 (AC2 non-degeneracy): every PROTECTED site completes bare against a
#   POPULATED B at HEAD — run with DEVAGENT_SCOPE_GUARD_OVERRIDE=1, which leg 5
#   proves equivalent to the pre-#572 behavior against a real baseline
#   extraction. A site that cannot reach rc 0 is a fixture bug.
# Leg 2 (AC2/AC6): the same bare invocations REFUSE with a message naming both
#   projects, both issues, the source, and the SCOPE MISMATCH tag. Exit status
#   alone is inadmissible (both observed misfires exited nonzero at HEAD).
# Leg 3 (AC3): B's devdoc is byte-unchanged by the refusing runs, measured via
#   git-tracked pathspecs — and the check itself is mutation-tested.
# Leg 4 (AC6): an EXEMPT site (wbs-show.sh) is demonstrably unaffected.
# Leg 5 (AC6/Q3): guard ON fires; the env opt-out restores baseline-captured
#   behavior on wbs-update.sh — the observed-misfire site — and does not leak.

load 'helpers/common'

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BASELINE_SHA="86efe8c"   # pre-#572 master; leg 5 skips its diff half if absent

setup() {
  devagent_test_setup    # projA = testproj; $SOURCE_DIR is its git repo

  # projB core (pointer on B, env pins unset) + a second commit so the
  # baseline..HEAD diff is exactly one file (mr.md's `files: 1 changed`)
  devagent_fixture_projB 1
  mkdir -p "$ISSUE_B/analysis" "$ISSUE_B/revisions/r1"
  ( cd "$SRC_B" && echo two > f.txt && git add f.txt && git commit -q -m c2 )
  B_BASE="$(git -C "$SRC_B" rev-parse HEAD~1)"
  B_HEAD="$(git -C "$SRC_B" rev-parse HEAD)"

  # B's devdoc is its own git repo (statusreport commits into it; leg 3
  # measures it via tracked pathspecs)
  ( cd "$DOC_B" && git init -q \
    && git config user.email b@example.com && git config user.name B )

  # Issue-9 artifacts
  echo "# projB#9 — fixture issue" > "$ISSUE_B/issue.md"
  cat > "$ISSUE_B/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [ ]  4. scope
- [ ]  9. implement
- [ ] 23. cleanup

## Log
EOF
  cat > "$ISSUE_B/mr.md" <<EOF
# fixture MR

## Evidence

suite: none @ $B_HEAD
files: 1 changed
EOF
  cat > "$ISSUE_B/revisions/r1/comments.md" <<'EOF'
# projB!9 — Comments

## Comments (1)

### @alice · 2026-08-01

fixture comment
EOF

  ( cd "$DOC_B" && git add -A && git commit -q -m fixture )

  # projB config extras: every opt-in consumer ON so bare completions are
  # observable. The bare keys continue the helper's still-open [project.projB]
  # table (nothing writes the config between the helper and this append).
  cat >> "$HOME/.claude/devagent/config.toml" <<EOF
commit_autostage = true
born_red         = true

[project.projB.permissions]
transition_issue = true
commit_devdoc    = true

[project.projB.issue_source]
backend    = "github"
repo       = "acme/projB"
dir_prefix = "Issue-"
EOF

  cat > "$HOME/.claude/devagent/state/projB.toml" <<EOF
active_issue = "Issue-9"
issue_dir    = "$ISSUE_B"
baseline_sha = "$B_BASE"
revision     = 1
mr_url       = "https://example.test/projB/mr/9"
EOF

  # (pointer + env-pin hygiene already done by devagent_fixture_projB)

  # stub issue backend (transition-draft-start) + code backend (comments),
  # both logging argv to the shared $DEVAGENT_STUB_LOG from devagent_test_setup
  STUB_BACKENDS="$DEVAGENT_TMP/stub-issue"
  mkdir -p "$STUB_BACKENDS"
  cat > "$STUB_BACKENDS/github.sh" <<EOF
#!/usr/bin/env bash
printf 'issue/github %s\n' "\$*" >> "$DEVAGENT_STUB_LOG"
EOF
  chmod +x "$STUB_BACKENDS/github.sh"
  CODE_STUB="$DEVAGENT_TMP/code-stub.sh"
  cat > "$CODE_STUB" <<EOF
#!/usr/bin/env bash
printf 'code %s\n' "\$*" >> "$DEVAGENT_STUB_LOG"
printf '### @bob · 2026-08-02\n\nstub comment\n'
EOF
  chmod +x "$CODE_STUB"
  export STUB_BACKENDS CODE_STUB
}
teardown() { devagent_test_teardown; }

# run a script bare from projA's tree; $1 = mode (override|guarded), rest = cmd
# PYTHONUTF8=1 pins the embedded-python stdout encoding: a locale-empty Git
# Bash shell otherwise inherits cp1252 and statusreport's '→' dies mid-write
# (register Issue-559 — pin the harness locale; WSL provides UTF-8 natively)
_from_a() {
  local mode="$1"; shift
  local ov=""
  [ "$mode" = override ] && ov="DEVAGENT_SCOPE_GUARD_OVERRIDE=1"
  run bash -c "cd '$SOURCE_DIR' && env $ov \
    PYTHONUTF8=1 \
    DEVAGENT_ISSUE_BACKEND_DIR='$STUB_BACKENDS' \
    DEVAGENT_CODE_BACKEND_CMD='$CODE_STUB' \
    bash $*"
}

@test "#572 AC2 leg 1: all 14 PROTECTED sites complete bare against populated B at HEAD (override)" {
  # 1. checklist-init — scaffolds a checklist via B's template registry
  mkdir -p "$DOC_B/Issue-9x"
  _from_a override "'$REPO/scripts/checklist-init.sh' '$DOC_B/Issue-9x'"
  [ "$status" -eq 0 ]; [ -f "$DOC_B/Issue-9x/checklist.md" ]
  # 2. wbs-init — creates B's WBS.md
  _from_a override "'$REPO/scripts/wbs-init.sh'"
  [ "$status" -eq 0 ]; [ -f "$DOC_B/WBS.md" ]
  # 3. wbs-update — reconciles Issue-9 into B's WBS (the observed misfire)
  _from_a override "'$REPO/scripts/wbs-update.sh'"
  [ "$status" -eq 0 ]
  run grep -c 'Issue-9' "$DOC_B/WBS.md"; [ "$output" -ge 1 ]
  # 4. born-red — B has no new tests: writes the NO-NEW-TESTS artifact
  _from_a override "'$REPO/scripts/born-red.sh'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$ISSUE_B/analysis/'*-born-red.txt"; [ "$status" -eq 0 ]
  # 5. record-scope — writes B's autostage manifest
  _from_a override "'$REPO/scripts/record-scope.sh'"
  [ "$status" -eq 0 ]; [ -f "$ISSUE_B/.devagent-scope" ]
  # 6. rederive — writes B's rederive artifact
  _from_a override "'$REPO/scripts/rederive.sh'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$ISSUE_B/analysis/'*-rederive.txt"; [ "$status" -eq 0 ]
  # 7. run-suite — writes B's suite-count artifact (no frameworks in B)
  _from_a override "'$REPO/scripts/run-suite.sh'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$ISSUE_B/analysis/'*-suite-count.txt"; [ "$status" -eq 0 ]
  # 8. preship-evidence — PASS about B's mr.md (consumes step 7's artifact)
  _from_a override "'$REPO/scripts/preship-evidence.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preship-evidence: PASS"* ]]
  # 9. next — reports B's next actionable (skill-backed) step
  _from_a override "'$REPO/scripts/next.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  # 10. transition-draft-start — fires B's transition on the stub tracker
  _from_a override "'$REPO/scripts/transition-draft-start.sh'"
  [ "$status" -eq 0 ]
  devagent_assert_logged "issue/github transition acme/projB 9 on_draft_start"
  # 11. depends — records into B's dependency graph
  _from_a override "'$REPO/scripts/depends.sh' Issue-9 on Issue-8"
  [ "$status" -eq 0 ]
  # 12. comments — fetches via the stub code backend into B's revisions/
  _from_a override "'$REPO/scripts/comments.sh'"
  [ "$status" -eq 0 ] || { echo "comments.sh failed rc=$status: $output"; false; }
  run grep -c 'stub comment' "$ISSUE_B/revisions/r1/comments.md"
  [ "$output" -ge 1 ]
  # 13. revise — appends Revision 2 to B's checklist
  _from_a override "'$REPO/scripts/revise.sh'"
  [ "$status" -eq 0 ] || { echo "revise.sh failed rc=$status: $output"; false; }
  run grep -c '^## Revision 2' "$ISSUE_B/checklist.md"; [ "$output" -eq 1 ]
  # 14. statusreport — writes and commits B's status report
  _from_a override "'$REPO/scripts/statusreport.sh'"
  [ "$status" -eq 0 ] || { echo "statusreport.sh failed rc=$status: $output"; false; }
  run bash -c "ls '$DOC_B/StatusReports/'*.md"; [ "$status" -eq 0 ]
}

@test "#572 AC2 leg 2: all 14 bare invocations refuse, naming both projects, both issues, and the source" {
  local checked=0 cmd
  mkdir -p "$DOC_B/Issue-9x"
  for cmd in \
    "'$REPO/scripts/born-red.sh'" \
    "'$REPO/scripts/checklist-init.sh' '$DOC_B/Issue-9x'" \
    "'$REPO/scripts/comments.sh'" \
    "'$REPO/scripts/depends.sh' list" \
    "'$REPO/scripts/next.sh'" \
    "'$REPO/scripts/preship-evidence.sh'" \
    "'$REPO/scripts/record-scope.sh'" \
    "'$REPO/scripts/rederive.sh'" \
    "'$REPO/scripts/revise.sh'" \
    "'$REPO/scripts/run-suite.sh'" \
    "'$REPO/scripts/statusreport.sh'" \
    "'$REPO/scripts/transition-draft-start.sh'" \
    "'$REPO/scripts/wbs-init.sh'" \
    "'$REPO/scripts/wbs-update.sh'" \
  ; do
    _from_a guarded "$cmd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SCOPE MISMATCH"* ]]
    [[ "$output" == *"projB"*    ]]
    [[ "$output" == *"Issue-9"*  ]]
    [[ "$output" == *"$TEST_PROJECT"* ]]
    [[ "$output" == *"Issue-1"*  ]]
    [[ "$output" == *"pointer"*  ]]
    checked=$((checked + 1))
  done
  # floor: every PROTECTED row was exercised (register: Issue-151)
  [ "$checked" -eq 14 ]
  # and nothing was fired at the stub tracker/backend by any refused run
  devagent_refute_logged "issue/github"
  devagent_refute_logged "code "
}

@test "#572 AC3 leg 3: B's devdoc is byte-unchanged by the refusing runs — and the check itself reddens on a planted write" {
  _snap() {  # porcelain (untracked+modified) + content hash over TRACKED paths
    git -C "$DOC_B" status --porcelain | sort
    git -C "$DOC_B" ls-files -z | sort -z \
      | xargs -0 -I{} sha256sum "$DOC_B/{}" | awk '{print $1}' | sha256sum
  }
  local before after
  mkdir -p "$DOC_B/Issue-9x"
  before="$(_snap)"
  local cmd
  for cmd in \
    "'$REPO/scripts/wbs-update.sh'" \
    "'$REPO/scripts/statusreport.sh'" \
    "'$REPO/scripts/revise.sh'" \
    "'$REPO/scripts/comments.sh'" \
    "'$REPO/scripts/record-scope.sh'" \
    "'$REPO/scripts/rederive.sh'" \
    "'$REPO/scripts/born-red.sh'" \
    "'$REPO/scripts/checklist-init.sh' '$DOC_B/Issue-9x'" \
    "'$REPO/scripts/wbs-init.sh'" \
  ; do
    _from_a guarded "$cmd"
    [ "$status" -ne 0 ]
  done
  after="$(_snap)"
  [ "$before" = "$after" ]
  # mutation 1: an APPEND to a tracked file must redden the check (the exact
  # Issue-553 shape: a one-line WBS append recorded as "no write landed")
  echo mutation >> "$DOC_B/Issue-9/issue.md"
  after="$(_snap)"
  [ "$before" != "$after" ]
  git -C "$DOC_B" checkout -q -- Issue-9/issue.md
  # mutation 2: a NEW untracked file must redden it too
  echo mutation > "$DOC_B/planted.txt"
  after="$(_snap)"
  [ "$before" != "$after" ]
}

@test "#572 AC6 leg 4: the EXEMPT wbs-show.sh is unaffected by the mismatch" {
  # give B a WBS first (override wbs-init, sanctioned)
  _from_a override "'$REPO/scripts/wbs-init.sh'"
  [ "$status" -eq 0 ]
  # bare, guard active, mismatch conditions: EXEMPT site still completes
  _from_a guarded "'$REPO/scripts/wbs-show.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE MISMATCH"* ]]
  [[ "$output" == *"WBS"* ]]
}

@test "#572 AC6 leg 5: guard ON fires on wbs-update; the opt-out restores baseline behavior; no leak" {
  # sanctioned setup: B gets a WBS
  _from_a override "'$REPO/scripts/wbs-init.sh'"
  [ "$status" -eq 0 ]
  cp "$DOC_B/WBS.md" "$DEVAGENT_TMP/wbs.pristine"

  # baseline half: extract the whole pre-#572 scripts tree and capture its
  # bare-run EFFECT against B (skipped when the pinned SHA is unreachable,
  # e.g. a shallow clone; the effect assertion below still runs)
  local have_baseline=0
  if git -C "$REPO" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
    have_baseline=1
    mkdir -p "$DEVAGENT_TMP/baseline"
    git -C "$REPO" archive "$BASELINE_SHA" scripts | tar -x -C "$DEVAGENT_TMP/baseline"
    _from_a guarded "'$DEVAGENT_TMP/baseline/scripts/wbs-update.sh'"
    [ "$status" -eq 0 ]        # the pre-#572 tree happily acts on B — the defect
    cp "$DOC_B/WBS.md" "$DEVAGENT_TMP/wbs.baseline-result"
    cp "$DEVAGENT_TMP/wbs.pristine" "$DOC_B/WBS.md"   # reset
  fi

  # ON (default): refuses, naming the mismatch; WBS untouched
  _from_a guarded "'$REPO/scripts/wbs-update.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE MISMATCH"* ]]
  run diff "$DOC_B/WBS.md" "$DEVAGENT_TMP/wbs.pristine"
  [ "$status" -eq 0 ]

  # OFF (per-call override): completes and reconciles B's WBS
  _from_a override "'$REPO/scripts/wbs-update.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE MISMATCH"* ]]
  run grep -c 'Issue-9' "$DOC_B/WBS.md"; [ "$output" -ge 1 ]

  # equivalence: the override run's EFFECT matches the baseline tree's run
  if [ "$have_baseline" -eq 1 ]; then
    run diff "$DOC_B/WBS.md" "$DEVAGENT_TMP/wbs.baseline-result"
    [ "$status" -eq 0 ]
  fi

  # no leak: a fresh bare invocation WITHOUT the variable still refuses
  _from_a guarded "'$REPO/scripts/wbs-update.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE MISMATCH"* ]]
}
