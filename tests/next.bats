#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [ ]  4. scope
- [ ]  5. improve
- [ ]  6. prune
- [ ]  7. tighten
- [ ]  8. branch
- [ ]  9. implement
- [ ] 23. cleanup
EOF
}

teardown() { teardown_tmp_devagent_home; }

# Second configured project. Three cases need one; keep the schema in one place.
_add_other_project() {
  cat >> "$DA_HOME/config.toml" <<EOF

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
EOF
}

@test "next on a skill-backed step prints the slash command to invoke" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope volk"* ]]   # #578: the command carries its scope
  [[ "$output" == *"volk/Issue-676"* ]]         # #578: the dispatch names project/issue
  [[ "$output" == *"skill-backed"* ]]
}

@test "next refuses to advance when current step is [!]" {
  sed -i 's/^- \[ \]  4\. scope/- [!]  4. scope/' "$DEVDOC/Issue-676/checklist.md"
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "next refuses without active issue" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "--through accepts a step name present in the checklist" {
  # First skill-backed step (scope) is still emitted; chain doesn't run
  # past it because we have no script for it. Just assert it doesn't error
  # and we did get the slash-command pointer.
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "--auto implies through cleanup" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "unknown --through step is rejected against this issue's checklist" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step"* ]]
}

@test "next when all steps done reports completion" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"All steps complete"* ]]
}

@test "next with no project arg uses the only configured project" {
  run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "next with no project arg respects DEVAGENT_ACTIVE_PROJECT env var" {
  # Add a second project so single-project resolution would die.
  _add_other_project
  DEVAGENT_ACTIVE_PROJECT=volk run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "next with no project arg dies when multiple projects configured" {
  _add_other_project
  run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 projects configured"* ]]
}

@test "next --auto emits CHAIN: marker on skill-backed steps" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  [[ "$output" == *"CHAIN: /devagent:next volk --auto"* ]]
}

@test "next --through propagates into CHAIN: marker" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAIN: /devagent:next volk --through tighten"* ]]
}

@test "next --through stops once the target is marked done" {
  # Simulate: tighten was the chain target and the skill marked it [x].
  # The model re-invokes /devagent:next --through tighten. We must NOT
  # advance into the next step (branch).
  sed -i 's/^- \[ \]  7\. tighten/- [x]  7. tighten/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"target 'tighten' is complete"* ]]
  [[ "$output" != *"/devagent:branch"* ]]
  [[ "$output" != *"CHAIN:"* ]]
}

@test "next without chain flags omits CHAIN: marker" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
  [[ "$output" != *"CHAIN:"* ]]
}

@test "next dispatches purely from THIS checklist, not a canonical step list" {
  # A planning-only issue's checklist with non-canonical numbering and
  # a custom skill-backed step that isn't in any global list. Authority
  # is the checklist; next.sh just reads it.
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [ ]  9. brainstorm
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:brainstorm"* ]]
}

@test "next prints the step_models advisory tier for the dispatched step (#150)" {
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.step_models]
default  = "sonnet"
thinking = "opus"
checking = "fable"
EOF
  # current step is 4 (scope) → default class → sonnet
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step 4 (scope) wants tier: sonnet"* ]]
}

@test "next prints NO advisory when step_models table is absent (#150)" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"wants tier"* ]]
}

@test "next per-step override beats the class tier (#150)" {
  # make step 9 (implement, thinking class) the current step
  sed -i -E 's/^- \[ \]  ([245678])\./- [x]  \1./' "$DEVDOC/Issue-676/checklist.md"
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.step_models]
default  = "sonnet"
thinking = "opus"
"9"      = "fable"
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step 9 (implement) wants tier: fable"* ]]
  [[ "$output" != *"wants tier: opus"* ]]
}

# --- #149: preship dispatch order + halt (regression locks — existing
# next.sh machinery over the new template line; born green by design) -------

@test "next dispatches preship after redmr, before ship (#149)" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
# Issue-676 — Workflow checklist

- [x] 16. redmr
- [ ] 17. preship
- [ ] 18. ship
EOC
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:preship"* ]]
}

@test "next halts on preship [!] — ship unreached (#149)" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
# Issue-676 — Workflow checklist

- [x] 16. redmr
- [!] 17. preship
- [ ] 18. ship
EOC
  echo "preship: planted failure list" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"STUCK"* ]]
  grep -qE '^- \[ \] +18\. ship' "$DEVDOC/Issue-676/checklist.md"
}

# --- #812: scripts/spike.sh is a helper /devagent:spike calls with its own verbs,
# not step 3's entry point. The real tree has it executable, so these run the
# collision for real. The cleanup row is there because --auto implies --through
# cleanup, which next.sh validates against the checklist.
_spike_checklist() {
  # The collision under test: without an executable spike.sh these pass vacuously.
  [ -x "$PLUGIN_ROOT/scripts/spike.sh" ]
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x]  0. pull
- [x]  2. draft
- [ ]  3. spike
- [ ]  4. scope
- [ ] 23. cleanup
EOC
}

@test "next on the spike row dispatches /devagent:spike, not spike.sh (#812)" {
  _spike_checklist
  local before
  before="$(cat "$DEVDOC/Issue-676/checklist.md")"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step 3 (spike), skill-backed"* ]]
  [[ "$output" == *"Run /devagent:spike volk"* ]]
  [[ "$output" != *"usage: spike.sh"* ]]
  [[ "$output" != *"first argument must be"* ]]
  [ "$(cat "$DEVDOC/Issue-676/checklist.md")" = "$before" ]
}

@test "next --auto on the spike row emits CHAIN: and exits 0 (#812)" {
  _spike_checklist
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run /devagent:spike volk"* ]]
  [[ "$output" == *"CHAIN: /devagent:next volk --auto"* ]]
  [[ "$output" != *"usage: spike.sh"* ]]
}

@test "next --auto halts (nonzero, no advance) when a dispatched script step exits nonzero (#337)" {
  # next.sh dispatches script steps with NO rc check (next.sh:~158) — halt-on-
  # failure exists ONLY via the file's `set -euo pipefail`. Pin it: mark 2-7 done
  # so step 8 (branch, a SCRIPT step) is current; branch.sh dies on the absent
  # .devagent-type; --auto must propagate nonzero and NOT advance. A refactor
  # wrapping the dispatch in `|| …` / an `if` converts halt into loop-past-failure.
  sed -i -E 's/^- \[ \]  ([24567])\./- [x]  \1./' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -ne 0 ]                                                  # halted nonzero
  grep -qE '^- \[ \]  8\. branch' "$DEVDOC/Issue-676/checklist.md"     # step 8 still pending
  # Non-vacuous "did not advance": next.sh emits `→ Run /devagent:implement` when
  # it reaches step 9 (skill-backed). Its ABSENCE proves the chain halted at 8.
  [[ "$output" != *"/devagent:implement"* ]]
  [[ "$output" != *"CHAIN:"* ]]                                       # no chain-continue emitted
}

@test "a chain hop dispatches the project the chain STARTED with (#578)" {
  # Second project, with its own devdoc, state and checklist — the hijack target.
  mkdir -p "$BATS_TEST_TMPDIR/other-devdoc/Issue-999"
  _add_other_project
  cat > "$DA_HOME/state/other.toml" <<ST
active_issue = "Issue-999"
issue_dir    = "$BATS_TEST_TMPDIR/other-devdoc/Issue-999"
ST
  # cleanup row required: --auto implies --through cleanup, which hop 2
  # validates against the RESOLVED project's checklist (next.sh:61-76).
  # Without it the unfixed tree dies before dispatching and the born-red
  # would fire on a path unrelated to the hijack.
  cat > "$BATS_TEST_TMPDIR/other-devdoc/Issue-999/checklist.md" <<'CL'
- [ ] 15. review
- [ ] 23. cleanup
CL

  # Hop 1: the chain starts for volk and emits its continuation.
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  local chain
  chain="$(printf '%s\n' "$output" | sed -n 's/^CHAIN: \/devagent:next //p')"
  [ -n "$chain" ]

  # A concurrent session moves the global pointer to the OTHER project.
  printf 'active_project = "other"\n' > "$DA_HOME/state/_active.toml"

  # Hop 2: the model invokes the emitted command verbatim.
  run "$PLUGIN_ROOT/scripts/next.sh" $chain
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]        # volk's next step
  [[ "$output" != *"/devagent:review"* ]]       # NOT other's next step
  # Hop 2's OWN continuation must carry the token too, or stability for hops 3+
  # rests on induction over the emitter rather than on the driven loop.
  [[ "$output" == *"CHAIN: /devagent:next volk"* ]]
  # An arg-resolved hop must NOT refresh the global pointer (#282 semantics —
  # the documented behavior change this fix trades for).
  grep -q 'active_project = "other"' "$DA_HOME/state/_active.toml"
}


@test "next STUCK hint names a command that actually clears the row (#587)" {
  # The fixture carries a ## Log section: unstuck.sh log_append requires one.
  f="$DEVDOC/Issue-676/checklist.md"
  cat > "$f" <<'EOC'
- [x]  0. pull
- [x]  2. draft
- [ ]  4. scope

## Log

## Revision 2

- [x]  2. draft
- [!]  4. scope
EOC
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"/devagent:unstuck"* ]]
  # Follow the hint, then assert the RECOVERED STATE, not the message.
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  # RELATIVE, not absolute. unstuck.sh's log_append inserts its entry at the END
  # of the `## Log` section — BEFORE `## Revision 2` — so every row below shifts
  # down by one (scripts/lib/log.sh). The heading shifts WITH them, so the
  # OFFSET is invariant: heading, blank, `- [x]  2. draft`, `- [~]  4. scope`
  # => the target row is rev2 + 3.
  rev2="$(grep -n '^## Revision 2' "$f" | cut -d: -f1)"
  [ -n "$rev2" ]
  run grep -cE '^- \[~\][[:space:]]+4\. scope' "$f"
  [ "$output" = "1" ]
  hit="$(grep -nE '^- \[~\][[:space:]]+4\. scope' "$f" | cut -d: -f1)"
  [ "$hit" -eq "$((rev2 + 3))" ]        # the ACTIVE block row, not rev-1's twin
  run grep -cE '^- \[ \][[:space:]]+4\. scope' "$f"
  [ "$output" = "1" ]                   # rev-1 copy untouched
  run grep -cE '^- \[!\]' "$f"
  [ "$output" = "0" ]
  # next now proceeds instead of halting.
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"STUCK"* ]]
}

# --- Phase breaks: a continued chain stops before implement/quality/updatewbs ---

# Mark every row before implement done, so implement (a default break) is current.
_at_implement() {
  sed -i -E 's/^- \[ \]  ([45678])\./- [x]  \1./' "$DEVDOC/Issue-676/checklist.md"
}

@test "phase breaks: every CHAIN: line marks the hop as a continued chain" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAIN: /devagent:next volk --auto --through cleanup --chained"* ]]
}

@test "phase breaks: a continued chain stops before implement with a fresh-session resume line" {
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --through cleanup --chained
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 9 (implement)"* ]]
  [[ "$output" == *"run /clear, then /devagent:next volk --auto"* ]]
  [[ "$output" != *"/devagent:implement"* ]]    # not dispatched
  [[ "$output" != *"CHAIN:"* ]]                 # the chain ends here
  # The resume line is the operator's own command: no --chained, no defaulted target.
  resume="$(printf '%s\n' "$output" | grep 'Resume:')"
  [[ "$resume" != *"--chained"* ]]
  [[ "$resume" != *"--through"* ]]
}

@test "phase breaks: the fresh session's first command runs the boundary step" {
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" != *"PHASE BREAK"* ]]
  [[ "$output" == *"/devagent:implement volk"* ]]
  [[ "$output" == *"CHAIN: /devagent:next volk --auto"* ]]
}

@test "phase breaks: an explicit --through survives into the resume line" {
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through cleanup --chained
  [ "$status" -eq 0 ]
  [[ "$output" == *"then /devagent:next volk --through cleanup"* ]]
}

@test "phase breaks: --no-breaks runs the boundary step and stays in the chain" {
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --no-breaks --chained
  [ "$status" -eq 0 ]
  [[ "$output" != *"PHASE BREAK"* ]]
  [[ "$output" == *"/devagent:implement volk"* ]]
  [[ "$output" == *"CHAIN: /devagent:next volk --auto --through cleanup --no-breaks --chained"* ]]
}

@test "phase breaks: phase_breaks = \"\" in the project disables them" {
  _at_implement
  printf 'phase_breaks = ""\n' >> "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  [ "$status" -eq 0 ]
  [[ "$output" != *"PHASE BREAK"* ]]
  [[ "$output" == *"/devagent:implement volk"* ]]
}

@test "phase breaks: [defaults] phase_breaks applies when the project sets none" {
  { printf '[defaults]\nphase_breaks = "scope"\n\n'; cat "$DA_HOME/config.toml"; } > "$DA_HOME/c.tmp"
  mv "$DA_HOME/c.tmp" "$DA_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 4 (scope)"* ]]
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  [[ "$output" != *"PHASE BREAK"* ]]            # implement is no longer a break
  [[ "$output" == *"/devagent:implement volk"* ]]
}

@test "phase breaks: a plain next (no chain flags) never breaks" {
  _at_implement
  run "$PLUGIN_ROOT/scripts/next.sh" volk --chained
  [ "$status" -eq 0 ]
  [[ "$output" != *"PHASE BREAK"* ]]
  [[ "$output" == *"/devagent:implement volk"* ]]
}

@test "phase breaks: a script step dispatched in-process makes the chain continued" {
  # The real ship -> mergetoall -> updatewbs hop: mergetoall is a SCRIPT step
  # (all_prs_branch unset => it marks itself [-]), then updatewbs is a break.
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x] 18. ship
- [ ] 19. mergetoall
- [ ] 20. updatewbs
- [ ] 23. cleanup

## Log
EOC
  printf 'branch = "fix/676-x"\n' >> "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  grep -qE '^- \[-\] 19\. mergetoall' "$DEVDOC/Issue-676/checklist.md"   # it ran
  [[ "$output" == *"PHASE BREAK before step 20 (updatewbs)"* ]]
  [[ "$output" != *"/devagent:updatewbs"* ]]
}

@test "plan budget: next warns at scope when imPlan.md is over 40 KB" {
  head -c 50000 /dev/zero | tr '\0' 'x' > "$DEVDOC/Issue-676/imPlan.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"imPlan.md is 48 KB, over draft's 40 KB Plan budget"* ]]
  [[ "$output" == *"/devagent:scope volk"* ]]      # advisory: scope still dispatches
}

@test "plan budget: no warning for a plan within budget" {
  printf '# plan\n' > "$DEVDOC/Issue-676/imPlan.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"Plan budget"* ]]
}

# --- #782: the CI line in the ship-to-merge window, and the block gate --------
# The real code/github.sh runs through the gh-stub (tests/fixtures/gh-stub `pr view`
# arm) into lib/ci.sh, so the backend grammar and its consumer are pinned together.
CI_URL=https://github.com/acme/volk/pull/9

# _ci_window <fixture> [gate] [backend]: issue shipped (row 18 [x], 19 [-]), mr_url
# recorded, current step 20. mr_url is appended with printf (never sed: the
# state-toml sed canary).
_ci_window() {
  local fx="$1" gate="${2:-}" backend="${3:-github}"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
${gate:+ci_gate = \"$gate\"}

[project.volk.code_source]
backend = "$backend"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x] 18. ship
- [-] 19. mergetoall
- [ ] 20. updatewbs
- [ ] 21. impact
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Log
EOC
  printf 'mr_url = "%s"\n' "$CI_URL" >> "$DA_HOME/state/volk.toml"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export DEVAGENT_GH="$BATS_TEST_TMPDIR/bin/gh"
  export GH_STUB_PR_CHECKS_FILE="$PLUGIN_ROOT/tests/fixtures/code-github/mr-checks-$fx.json"
  export GH_STUB_PR_CHECKS_LOG="$BATS_TEST_TMPDIR/pr-checks.log"
}

_ci_fixture() { export GH_STUB_PR_CHECKS_FILE="$PLUGIN_ROOT/tests/fixtures/code-github/mr-checks-$1.json"; }
_ci_rows() { grep '^- \[' "$DEVDOC/Issue-676/checklist.md"; }
_ci_count() { grep -c '^CI ' <<<"$output" || true; }

@test "#782 report: a FAILURE plus an IN_PROGRESS rollup prints CI FAILED and dispatches step 20 as today" {
  _ci_window red
  local before; before="$(_ci_rows)"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI FAILED: $CI_URL (head a1b2c3d): bats shard 2 of 4 https://github.com/acme/volk/actions/runs/1/job/12"* ]]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  [ "$(_ci_rows)" = "$before" ]
}

@test "#782 report: all IN_PROGRESS prints CI PENDING: 2 of 2 checks still running" {
  _ci_window pending
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI PENDING: 2 of 2 checks still running on $CI_URL (head a1b2c3d): bats shard 1 of 4, lint"* ]]
}

@test "#782 report: [] prints CI NONE: no checks reported" {
  _ci_window none
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI NONE: no checks reported on $CI_URL (head a1b2c3d)"* ]]
}

@test "#782 report: state MERGED prints no CI line" {
  _ci_window merged
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_ci_count)" -eq 0 ]
  [ "$(cat "$GH_STUB_PR_CHECKS_LOG")" = pr-checks ]          # positive control: it read
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
}

@test "#782 report: gh exit 1 prints CI UNKNOWN: <url>: gh exited 1" {
  _ci_window none
  GH_STUB_PR_CHECKS_RC=1 run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI UNKNOWN: $CI_URL: gh exited 1" <<<"$output"
}

@test "#782 report: a read past DEVAGENT_CI_READ_SECS=2 prints CI UNKNOWN: <url>: timed out after 2s within 8 s" {
  _ci_window none
  local t0=$SECONDS
  DEVAGENT_CI_READ_SECS=2 GH_STUB_PR_CHECKS_SLEEP=30 run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI UNKNOWN: $CI_URL: timed out after 2s" <<<"$output"
  [ $((SECONDS - t0)) -lt 8 ]                                 # the stub would hang 30 s
}

@test "#782 report: with timeout(1) hidden the read prints CI UNKNOWN: <url>: timeout(1) not on PATH" {
  load 'lib/doctor-harness'
  _ci_window red
  curated_path_without timeout       # shadows timeout's dir (~1 s for a large /usr/bin)
  if command -v timeout; then false; fi
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI UNKNOWN: $CI_URL: timeout(1) not on PATH" <<<"$output"
  [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]                           # no unbounded call was made
}

@test "#782 a CANCELLED then later SUCCESS run of one check prints CI PASSED" {
  _ci_window superseded
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI PASSED: 1 checks on $CI_URL (head a1b2c3d)" <<<"$output"
}

@test "#782 every invocation in the window prints exactly one CI line" {
  _ci_window pending
  local row flags
  for row in 20 21 22; do
    for flags in "" "--auto"; do
      # shellcheck disable=SC2086  # flags is "" or one word
      run "$PLUGIN_ROOT/scripts/next.sh" volk $flags
      [ "$status" -eq 0 ]
      [ "$(_ci_count)" -eq 1 ] || { echo "row $row flags '$flags': $(_ci_count) lines"; false; }
    done
    sed -i -E "s/^- \[ \] +$row\./- [x] $row./" "$DEVDOC/Issue-676/checklist.md"
  done
}

@test "#782 a checklist with no ship row and mr_url set runs as before, with no CI line and no read" {
  _ci_window red
  sed -i '/18\. ship/d' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_ci_count)" -eq 0 ]
  [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
}

@test "#782 before ship: no CI line and no read" {
  _ci_window red
  sed -i 's/^- \[x\] 18\. ship/- [ ] 18. ship/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$(_ci_count)" -eq 0 ]
  [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
}

@test "#782 block: red marks step 20 [!] with the CI FAILED reason" {
  _ci_window red block
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 1 ]
  grep -qE '^- \[!\] 20\. updatewbs' "$DEVDOC/Issue-676/checklist.md"
  grep -qF "Reason:      CI FAILED: $CI_URL" "$DEVDOC/Issue-676/STUCK"
  [[ "$output" != *"→ Run"* ]]
}

@test "#782 block: pending holds step 20, prints Resume with the run's flags, exits 0, marks nothing, no CHAIN:" {
  _ci_window pending block
  local before; before="$(_ci_rows)"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  grep -qxF "CI gate: holding step 20 (updatewbs) until CI finishes; nothing was marked" <<<"$output"
  grep -qxF "  Resume once CI has finished: run /clear, then /devagent:next volk --auto" <<<"$output"
  [ "$(_ci_rows)" = "$before" ]
  [ ! -e "$DEVDOC/Issue-676/STUCK" ]
  [[ "$output" != *"CHAIN:"* ]]
  [[ "$output" != *"→ Run"* ]]
}

@test "#782 block: green dispatches step 20 normally" {
  _ci_window green block
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  grep -qF "CI PASSED: 3 checks on $CI_URL" <<<"$output"
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
}

@test "#782 block: red → [!] → unstuck → green dispatches step 20" {
  _ci_window red block
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$DEVDOC/Issue-676"
  [ "$status" -eq 0 ]
  _ci_fixture green
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
}

@test "#782 ci_gate = \"maybe\" dies with the exact message" {
  _ci_window green maybe
  local before; before="$(_ci_rows)"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"ci_gate must be report, block or off (got 'maybe')"* ]]
  [ "$(_ci_rows)" = "$before" ]
}

@test "#782 ci_gate = \"off\" makes no read" {
  _ci_window red off
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
  [ "$(_ci_count)" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
}

@test "#782 a shipped issue with mr_url and no ci_seen_* prints a CI line and records ci_seen_head and ci_seen_at" {
  _ci_window pending
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_ci_count)" -eq 1 ]
  local head at
  head="$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.ci_seen_head)"
  at="$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.ci_seen_at)"
  [ "$head" = a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 ]
  [[ "$at" =~ ^[0-9]+$ ]]
}

@test "#782 no mr_url: no CI line and no read" {
  _ci_window red
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" unset "$DA_HOME/state/volk.toml" mr_url
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ "$(_ci_count)" -eq 0 ]
  [ ! -e "$GH_STUB_PR_CHECKS_LOG" ]
}

@test "#782 identical results write one ci: log line" {
  _ci_window pending
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$(grep -c '  ci: ' "$DEVDOC/Issue-676/checklist.md")" -eq 1 ]
  _ci_fixture red
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$(grep -c '  ci: ' "$DEVDOC/Issue-676/checklist.md")" -eq 2 ]
}

@test "#782 a backend without mr-checks prints CI NOT CHECKED: custom has no mr-checks" {
  _ci_window red "" custom
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI NOT CHECKED: custom has no mr-checks" <<<"$output"
}

@test "#782 the CI line comes directly before the PHASE BREAK lines" {
  _ci_window pending
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI PENDING: "*$'\n'"PHASE BREAK before step 20 (updatewbs)"* ]]
}
