#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'helpers/common'

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
  _ci_fixture "$fx"
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

@test "#782 block: no checks inside the grace holds step 20 and marks nothing" {
  _ci_window none block
  local before; before="$(_ci_rows)"
  DEVAGENT_CI_GRACE_SECS=600 run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  grep -qF "CI NONE: no checks reported on $CI_URL" <<<"$output"
  grep -qxF "CI gate: holding step 20 (updatewbs) until CI finishes; nothing was marked" <<<"$output"
  [ "$(_ci_rows)" = "$before" ]
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

@test "#782 a hand-annotated ship row (18. ship:) still prints the CI line" {
  _ci_window green
  local f="$DEVDOC/Issue-676/checklist.md" body
  body="$(<"$f")"
  printf '%s\n' "${body/- \[x\] 18. ship/- [x] 18. ship:}" > "$f"
  grep -qxF -- '- [x] 18. ship:' "$f"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qF "CI PASSED: 3 checks on $CI_URL" <<<"$output"
}

@test "#782 a backend without mr-checks prints CI NOT CHECKED: custom has no mr-checks" {
  _ci_window red "" custom
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  grep -qxF "CI NOT CHECKED: custom has no mr-checks" <<<"$output"
}

@test "#1016 next prints CI not applicable: local code backend once and never calls mr-checks (AC 8)" {
  _ci_window red "" local
  local marker="$BATS_TEST_TMPDIR/local-called"
  mkdir -p "$BATS_TEST_TMPDIR/code"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit 2\n' "$marker" > "$BATS_TEST_TMPDIR/code/local.sh"
  chmod +x "$BATS_TEST_TMPDIR/code/local.sh"
  export DEVAGENT_CODE_BACKEND_DIR="$BATS_TEST_TMPDIR/code"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "CI not applicable: local code backend" <<<"$output")" -eq 1 ]
  [ "$(_ci_count)" -eq 1 ]
  [ ! -e "$marker" ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$(grep -c '  ci: ' "$DEVDOC/Issue-676/checklist.md")" -eq 1 ]
  # ci_gate = "block" does not hold the step.
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.ci_gate '"block"'
  local before; before="$(_ci_rows)"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  [ "$(_ci_rows)" = "$before" ]
  [ ! -e "$marker" ]
}

@test "#782 the CI line comes directly before the PHASE BREAK lines" {
  _ci_window pending
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI PENDING: "*$'\n'"PHASE BREAK before step 20 (updatewbs)"* ]]
}

# --- #885: the merge step (mergemr) in the chain ---------------------------------
# mergemr.sh runs for real over a stub code backend (DEVAGENT_CODE_BACKEND_DIR):
# mr-view serves $MM_VIEW, mr-checks (next.sh's own #782 read) its check lines,
# merge-mr logs to $MM_MERGES; every verb is counted in $MM_CALLS. The fixture checklist has a
# mergemr row (the templates gain it in a later commit).
MM_URL=https://github.com/acme/volk/pull/9
MM_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# _mm_view <state> <checks: pass|pending|none> [mergestate]: the stub's mr-view reply.
_mm_view() {
  local mc=-
  [ "$1" = merged ] && mc=cccccccccccccccccccccccccccccccccccccccc
  {
    printf 'state\t%s\nhead\t%s\n' "$1" "$MM_HEAD"
    case "$2" in
      pass)    printf 'pass\tci\t-\n' ;;
      pending) printf 'pending\tci\t-\n' ;;
    esac
    printf 'draft\tfalse\nbase\tmain\nmergeable\tMERGEABLE\nmergestate\t%s\n' "${3:-CLEAN}"
    printf 'automerge\toff\nqueue\tfalse\nnumber\t9\ntitle\tFix it\nmergecommit\t%s\ncommits\t1\t1\n' "$mc"
  } > "$MM_VIEW"
}

# _mm_window [merge_mr] [ci_gate]: shipped (17-18 [x], 19 [-]), mr_url and
# verified_head recorded, current step 20 mergemr, PR open with green CI.
_mm_window() {
  local mm="${1:-false}" gate="${2:-}"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
default_baseline = "origin/main"
${gate:+ci_gate = \"$gate\"}

[project.volk.permissions]
push_mr  = true
merge_mr = $mm

[project.volk.code_source]
backend  = "github"
upstream = "acme/volk"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x] 17. preship
- [x] 18. ship
- [-] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
- [ ] 22. impact
- [ ] 23. lessonslearned
- [ ] 24. cleanup

## Log
EOC
  printf 'mr_url = "%s"\nverified_head = "%s"\n' "$MM_URL" "$MM_HEAD" >> "$DA_HOME/state/volk.toml"
  export MM_CALLS="$BATS_TEST_TMPDIR/mm-calls" MM_VIEW="$BATS_TEST_TMPDIR/mm-view"
  export MM_MERGES="$BATS_TEST_TMPDIR/mm-merges"
  : > "$MM_CALLS"
  mkdir -p "$BATS_TEST_TMPDIR/code"
  cat > "$BATS_TEST_TMPDIR/code/github.sh" <<'EOS'
#!/usr/bin/env bash
v="$1"; shift
printf '%s\n' "$v" >> "$MM_CALLS"
case "$v" in
  push-branch) exit 0 ;;
  create-mr) echo "https://github.com/acme/volk/pull/9" ;;
  branch-exists|merged-pr-head) exit 1 ;;
  mr-view) cat "$MM_VIEW" ;;
  mr-checks) grep -E $'^(state|head|pass|pending|fail)\t' "$MM_VIEW" ;;
  merge-mr) printf '%s\n' "$*" >> "$MM_MERGES" ;;
  *) exit 2 ;;
esac
EOS
  chmod +x "$BATS_TEST_TMPDIR/code/github.sh"
  export DEVAGENT_CODE_BACKEND_DIR="$BATS_TEST_TMPDIR/code"
  _mm_view open pass
}

_mm_rows()  { grep '^- \[' "$DEVDOC/Issue-676/checklist.md"; }
_mm_calls() { grep -cx "$1" "$MM_CALLS" || true; }
_mm_row()   { grep -qxF -- "- [$1] $2. $3" "$DEVDOC/Issue-676/checklist.md"; }
MM_WAIT="WAITING at step 20 (mergemr): the PR is not merged yet; state is on disk. Re-check later: /devagent:next volk"

# --- #933: the break before updatewbs under the built-in default -----------------
# _mm_mark N G: set row N of Issue-676's checklist to glyph G (fails if no row N).
_mm_mark() { mark_step "$DEVDOC/Issue-676/checklist.md" "$1" "$2"; }
# _mm_done_through N: rows 17..N [x] (19 mergetoall stays [-]), so step N+1 is current.
# Checklist rows only: never touches state/volk.toml or config.toml.
_mm_done_through() {
  local n
  for n in $(seq 17 "$1"); do
    (( n == 19 )) && continue
    _mm_mark "$n" x || return 1
  done
}
# Config writes go AFTER _mm_window (which rewrites config.toml).
_mm_cfg() { devagent_config_set "$DA_HOME/config.toml" "$1" "$2"; }
_no_break() { [ "$(grep -c 'PHASE BREAK' <<<"$output" || true)" -eq 0 ]; }
_breaks_at_updatewbs() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 21 (updatewbs)"* ]]
  [[ "$output" != *"→ Run /devagent:updatewbs"* ]]
}
# _mm_two_revisions [ROW]: revision 1 merged through cleanup; revision 2 shipped,
# with ROW (e.g. `- [-] 20. mergemr`) as its mergemr row, or none when omitted.
_mm_two_revisions() {
  local rows="- [x] 17. preship
- [x] 18. ship
- [-] 19. mergetoall"
  {
    printf 'Active revision: 2\n\n## Revision 1\n\n%s\n' "$rows"
    printf '%s\n' "- [x] 20. mergemr" "- [x] 21. updatewbs" "- [x] 22. impact" \
      "- [x] 23. lessonslearned" "- [x] 24. cleanup"
    printf '\n## Revision 2\n\n%s\n' "$rows"
    [ -z "${1:-}" ] || printf '%s\n' "$1"
    printf '%s\n' "- [ ] 21. updatewbs" "- [ ] 22. impact" "- [ ] 23. lessonslearned" \
      "- [ ] 24. cleanup"
    printf '\n## Log\n'
  } > "$DEVDOC/Issue-676/checklist.md"
}

@test "#885 #933 --auto from ship runs ship, mergetoall, mergemr, then continues to updatewbs" {
  _mm_window false
  # Precondition: ship not run yet, nothing recorded; the branch carries one commit
  # past the baseline; mergetoall auto-skips (no all_prs_branch); the PR is merged,
  # so mergemr's rule 3 gives [x] whatever merge_mr says.
  sed -i -E 's/^- \[x\] 18\. ship/- [ ] 18. ship/; s/^- \[-\] 19\./- [ ] 19./' "$DEVDOC/Issue-676/checklist.md"
  printf 'active_issue = "Issue-676"\nissue_dir    = "%s"\nbranch = "fix/676-x"\n' \
    "$DEVDOC/Issue-676" > "$DA_HOME/state/volk.toml"
  local src="$BATS_TEST_TMPDIR/volk"
  git -c init.defaultBranch=main init -q "$src"
  git -C "$src" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m base
  printf 'baseline_sha = "%s"\n' "$(git -C "$src" rev-parse main)" >> "$DA_HOME/state/volk.toml"
  git -C "$src" checkout -q -b fix/676-x
  git -C "$src" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m work
  echo "MR body" > "$DEVDOC/Issue-676/mr.md"
  echo "Fix it" > "$DEVDOC/Issue-676/.devagent-title"
  _mm_view merged pass
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  echo "$output"
  [ "$status" -eq 0 ]
  _mm_row x 18 ship
  _mm_row - 19 mergetoall
  _mm_row x 20 mergemr
  _mm_row ' ' 21 updatewbs
  [[ "$output" == *"step 18 (ship), script-backed"*"step 19 (mergetoall), script-backed"*"step 20 (mergemr), script-backed"*"→ Run /devagent:updatewbs volk"* ]]
  _no_break
  [[ "$output" == *"CHAIN: /devagent:next volk --auto --through cleanup --chained"* ]]
  grep -qE '^mr_url = "https://github.com/acme/volk/pull/9"' "$DA_HOME/state/volk.toml"
  [ "$(_mm_calls mr-checks)" -eq 0 ]
  [ ! -e "$MM_MERGES" ]
}

@test "#885 mergemr [?] stops --auto with exit 0 and the WAITING line" {
  _mm_window false
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  echo "$output"
  [ "$status" -eq 0 ]
  _mm_row '?' 20 mergemr
  grep -qxF "$MM_WAIT --auto" <<<"$output"
  [[ "$output" == *"mergemr: waiting (8): waiting for merge ("* ]]
  [[ "$output" != *"CHAIN:"* ]]
  [[ "$output" != *"PHASE BREAK"* ]]
  [[ "$output" != *"did not mark itself"* ]]
  [[ "$output" != *"(updatewbs)"* ]]
  [ ! -e "$DEVDOC/Issue-676/STUCK" ]
  [ ! -e "$MM_MERGES" ]
}

@test "#885 rerunning next on [?] re-reads; [x] once merged" {
  _mm_window false
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  _mm_row '?' 20 mergemr
  grep -qxF "$MM_WAIT" <<<"$output"
  _mm_view merged pass
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"blocked-on-external"* ]]
  [[ "$output" == *"dispatch: volk/Issue-676 — step 20 (mergemr), script-backed"* ]]
  _mm_row x 20 mergemr
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  [[ "$output" != *"WAITING"* ]]
  [ "$(_mm_calls mr-view)" -eq 2 ]
}

@test "#885 no CI line on the mergemr iteration" {
  _mm_window false
  # Waiting: mergemr's own read prints the one CI line; next.sh reads nothing.
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CI ' <<<"$output" || true)" -eq 1 ]
  grep -qF "CI PASSED: 1 checks on $MM_URL" <<<"$output"
  [ "$(_mm_calls mr-checks)" -eq 0 ]
  # Merged, then the loop reaches updatewbs: mergemr's read counts for this
  # invocation too, so next.sh makes no second read.
  _mm_view merged pass
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  echo "$output"
  [ "$status" -eq 0 ]
  _mm_row x 20 mergemr
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  [ "$(_mm_calls mr-checks)" -eq 0 ]
}

@test "#885 ci_gate=block with pending CI still dispatches mergemr" {
  _mm_window true block
  _mm_view open pending BLOCKED
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CI gate: holding"* ]]
  [[ "$output" == *"step 20 (mergemr), script-backed"* ]]
  _mm_row '?' 20 mergemr
  [[ "$output" == *"mergemr: waiting (16): CI PENDING: 1 of 1 checks still running on $MM_URL"* ]]
  grep -qxF "$MM_WAIT --auto" <<<"$output"
  [ "$(_mm_calls mr-checks)" -eq 0 ]
  [ ! -e "$MM_MERGES" ]
}

@test "#885 [?] on another step keeps the park hint" {
  _mm_window false
  sed -i -E 's/^- \[ \] 20\./- [x] 20./; s/^- \[ \] 21\./- [?] 21./' "$DEVDOC/Issue-676/checklist.md"
  local before; before="$(_mm_rows)"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"Step 21 (updatewbs) is [?] blocked-on-external. Consider /devagent:park."* ]]
  [[ "$output" != *"dispatch:"* ]]
  [[ "$output" != *"WAITING"* ]]
  [ "$(_mm_rows)" = "$before" ]
}

@test "#933 each --chained hop at rows 21-24 prints its dispatch line and no PHASE BREAK (built-in default, mergemr [x])" {
  _mm_window false
  local hop n name
  for hop in 21:updatewbs 22:impact 23:lessonslearned 24:cleanup; do
    n="${hop%%:*}" name="${hop#*:}"
    _mm_done_through $((n - 1))
    run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
    echo "--- hop $n: $output"
    [[ "$output" == *"dispatch: volk/Issue-676 — step $n ($name),"* ]]
    _no_break
    if (( n < 24 )); then
      [ "$status" -eq 0 ]
      [[ "$output" == *"→ Run /devagent:$name volk"* ]]
    else
      # cleanup.sh is script-backed: it stops at its lessons gate (no
      # lessonsLearned.md is seeded) before any git side effect.
      [[ "$output" == *"lessonslearned is [x] but there is no lessonsLearned.md"* ]]
    fi
  done
}

@test "#933 an explicit project or [defaults] phase_breaks naming updatewbs still breaks with mergemr [x]" {
  _mm_window false
  _mm_done_through 20
  local key
  for key in project.volk.phase_breaks defaults.phase_breaks; do
    _mm_cfg "$key" "implement quality updatewbs"
    run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
    echo "--- $key: $output"
    _breaks_at_updatewbs
    devagent_config_unset "$DA_HOME/config.toml" "$key"
  done
}

@test "#933 phase_breaks = \"\" and --no-breaks run through updatewbs where the default would break" {
  _mm_window false
  _mm_done_through 20
  _mm_mark 20 -        # ship [x], mergemr [-]: abandoned PR, where the default breaks (guard test)
  # (ii) --no-breaks under the built-in config.
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained --no-breaks
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  _no_break
  # (i) phase_breaks = "".
  _mm_cfg project.volk.phase_breaks ""
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  _no_break
}

@test "#933 guard: zero-diff mergemr [-] with ship [-] passes; [-] after a real ship keeps the break" {
  _mm_window false
  _mm_done_through 20
  # (ii) ship [x], mergemr [-]: an abandoned PR keeps the break.
  _mm_mark 20 -
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 21 (updatewbs)"* ]]
  grep -qxF "  Resume: run /clear, then /devagent:next volk --auto" <<<"$output"
  # (i) ship, mergetoall and mergemr all [-]: no PR existed (mergemr rule 1).
  _mm_mark 18 -
  _mm_mark 19 -
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ Run /devagent:updatewbs volk"* ]]
  _no_break
}

@test "#933 guard reads the active revision only" {
  _mm_window false
  # Revision 1 merged; revision 2's mergemr is [-] after a real ship (no merge).
  # A file-wide first-match read would see revision 1's [x] and skip the break.
  _mm_two_revisions "- [-] 20. mergemr"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  _breaks_at_updatewbs
}

@test "#933 built-in default still breaks before implement and quality when mergemr is [x]" {
  _mm_window false
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [x]  5. improve
- [x]  6. prune
- [x]  7. tighten
- [x]  8. branch
- [ ]  9. implement
- [ ] 10. quality
- [ ] 18. ship
- [x] 20. mergemr
- [ ] 21. updatewbs
- [ ] 24. cleanup

## Log
EOC
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 9 (implement)"* ]]
  sed -i -E 's/^- \[ \]  9\./- [x]  9./' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHASE BREAK before step 10 (quality)"* ]]
}

# _guard_home FILE: some single line carrying both `mergemr` and `[x]` lies in the
# phase-breaks passage (the 12 lines from the first phase_breaks/PHASE BREAK line).
_guard_home() {
  awk '!s && tolower($0) ~ /phase_breaks|phase break/ { s = NR }
       s && NR <= s + 12 && index($0, "mergemr") && index($0, "[x]") { ok = 1 }
       END { exit (ok ? 0 : 1) }' "$1"
}

@test "#933 every phase_breaks home states the mergemr guard" {
  local homes=(docs/specs/2026-05-19-devagent-plugin-design.md docs-site/workflow.md
               docs/configuration.md templates/config.toml.skel)
  local h passed=0 planted=0 copy
  for h in "${homes[@]}"; do
    if _guard_home "$PLUGIN_ROOT/$h"; then passed=$((passed + 1)); else echo "no guard line: $h"; fi
    # Planted control: the same home without its guard lines must fail.
    copy="$BATS_TEST_TMPDIR/planted-${h//\//_}"
    awk '!(index($0, "mergemr") && index($0, "[x]"))' "$PLUGIN_ROOT/$h" > "$copy"
    if _guard_home "$copy"; then planted=$((planted + 1)); fi
  done
  [ "$planted" -eq 0 ]
  [ "$passed" -eq "${#homes[@]}" ]
}

@test "#933 guard: an active revision with no mergemr row keeps the break despite an older revision's [x]" {
  _mm_window false
  # A revision block from a pre-#899 template override has no mergemr row; the
  # by-name read's file-wide fallback must not borrow revision 1's merge.
  _mm_two_revisions
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto --chained
  echo "$output"
  _breaks_at_updatewbs
}

# --- #1029: chain target resolved by name in the active revision ---
# The chain-target guard and the --through validation read the target's OWN row
# in the active revision block, by name. An older block that numbers the target
# differently must neither stop the chain early nor let it run past the target.

# _1029_root: a copied plugin root (scripts/ + templates/) with every step-named
# executable script replaced by a stub that prints STUB-<name> and exits 0
# without marking. Sets the GLOBAL `root`. The step set comes from the shipped
# standard template, not a hand-kept list.
_1029_root() {
  root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root/scripts"
  cp -r "$PLUGIN_ROOT/scripts/." "$root/scripts/"
  cp -r "$PLUGIN_ROOT/templates" "$root/"
  local _num n
  while read -r _num n; do
    if [[ -x "$root/scripts/$n.sh" ]]; then
      printf '#!/usr/bin/env bash\necho STUB-%s\nexit 0\n' "$n" > "$root/scripts/$n.sh"
    fi
  done < <(canonical_steps)
}

# Issue-9 shape: the older block numbers cleanup 23; the active block numbers it 24.
_1029_issue9() {
  local active_cleanup="${1:- }"
  cat > "$DEVDOC/Issue-676/checklist.md" <<EOC
# Issue-9
- [x] 21. impact
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Revision 2

- [x] 22. impact
- [x] 23. lessonslearned
- [$active_cleanup] 24. cleanup
EOC
}

# Spike shape: spike exists only in the older block (done there unless given).
_1029_spike() {
  local old_spike="${1:-x}"
  cat > "$DEVDOC/Issue-676/checklist.md" <<EOC
- [x]  0. pull
- [$old_spike]  3. spike
- [ ]  4. scope
- [ ] 24. cleanup

## Revision 2

- [x]  2. draft
- [ ]  4. scope
- [ ] 24. cleanup
EOC
}

@test "#1029 AC1: --auto on a renumbered Revision 2 dispatches cleanup instead of false-stopping" {
  _1029_root
  _1029_issue9
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [[ "$output" == *"dispatch: volk/Issue-676 — step 24 (cleanup)"* ]]
  [[ "$output" == *"STUB-cleanup"* ]]
  [[ "$output" != *"Chain target 'cleanup' is complete"* ]]
  ! grep -qxE '[ x~?!P-]' <<<"$output" || false
}

@test "#1029 AC2: a done target in the active block stops though the older block's twin is pending" {
  _1029_root
  _1029_issue9 x
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [[ "$output" == *"Chain target 'cleanup' is complete; stopping."* ]]
  [[ "$output" != *"dispatch:"* ]]
  [[ "$output" != *"STUB-"* ]]
}

@test "#1029 AC3: --through preship on a renumbered Revision 2 stops instead of dispatching ship" {
  _1029_root
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
# Issue-8
- [x] 14. redmr
- [ ] 21. preship
- [ ] 15. ship

## Revision 2

- [x] 16. redmr
- [x] 17. preship
- [ ] 18. ship
- [-] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
EOC
  cp "$DEVDOC/Issue-676/checklist.md" "$BATS_TEST_TMPDIR/before.md"
  run bash "$root/scripts/next.sh" volk --through preship
  echo "$output"
  [[ "$output" == *"Chain target 'preship' is complete; stopping."* ]]
  [[ "$output" != *"STUB-ship"* ]]
  [[ "$output" != *"dispatch:"* ]]
  cmp "$BATS_TEST_TMPDIR/before.md" "$DEVDOC/Issue-676/checklist.md"
}

# Uniform shape: both blocks number cleanup 24; the older one is done.
_1029_uniform() {
  local active_cleanup="$1"
  cat > "$DEVDOC/Issue-676/checklist.md" <<EOC
## Revision 1

- [x] 21. updatewbs
- [x] 22. impact
- [x] 23. lessonslearned
- [x] 24. cleanup

## Revision 2

- [x] 21. updatewbs
- [x] 22. impact
- [x] 23. lessonslearned
- [$active_cleanup] 24. cleanup
EOC
}

@test "#1029 AC4 case A: identically numbered blocks, done target stops as today" {
  _1029_root
  _1029_uniform x
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [[ "$output" == *"Chain target 'cleanup' is complete; stopping."* ]]
  [[ "$output" != *"dispatch:"* ]]
}

@test "#1029 AC4 case B: identically numbered blocks, pending target dispatches as today" {
  _1029_root
  _1029_uniform ' '
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [[ "$output" == *"dispatch: volk/Issue-676 — step 24 (cleanup)"* ]]
  [[ "$output" == *"STUB-cleanup"* ]]
}

@test "#1029: --through a step only in an older block is refused with a remedy, nothing dispatched" {
  _1029_root
  _1029_spike
  cp "$DEVDOC/Issue-676/checklist.md" "$BATS_TEST_TMPDIR/before.md"
  run bash "$root/scripts/next.sh" volk --through spike
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--through 'spike': that step is only in an older revision block of"* ]]
  [[ "$output" == *"where it is already done. Choose a --through step from the active revision."* ]]
  [[ "$output" != *"Run /devagent:spike"* ]]
  [[ "$output" != *"dispatch:"* ]]
  [[ "$output" != *"STUB-"* ]]
  cmp "$BATS_TEST_TMPDIR/before.md" "$DEVDOC/Issue-676/checklist.md"
}

@test "#1029: --through a step pending only in an older block offers to run it directly" {
  _1029_root
  _1029_spike ' '
  run bash "$root/scripts/next.sh" volk --through spike
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--through 'spike': that step is only in an older revision block of"* ]]
  [[ "$output" == *"Run /devagent:spike volk directly, or choose a --through step from the active revision."* ]]
  [[ "$output" != *"dispatch:"* ]]
}

@test "#1029: --auto whose cleanup is only in an older block names --auto in the refusal" {
  _1029_root
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x] 21. impact
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Revision 2

- [x] 22. impact
- [ ] 23. lessonslearned
EOC
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--auto (implies --through 'cleanup'): that step is only in an older revision block of"* ]]
  [[ "$output" != *"dispatch:"* ]]
}

@test "#1029: a hand-annotated target row in the active block is the chain target" {
  _1029_root
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x] 21. impact
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Revision 2

- [x] 22. impact
- [x] 23. lessonslearned
- [ ] 24. cleanup: note
EOC
  run bash "$root/scripts/next.sh" volk --auto
  echo "$output"
  [[ "$output" == *"dispatch: volk/Issue-676 — step 24 (cleanup)"* ]]
  [[ "$output" == *"STUB-cleanup"* ]]
}

@test "#1029: --through a name absent from the whole file keeps the unknown-step message" {
  _1029_root
  _1029_spike
  run bash "$root/scripts/next.sh" volk --through nonsense
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step 'nonsense' (not present in"* ]]
  [[ "$output" != *"older revision block"* ]]
}

@test "#1029: --through is matched by exact name, not as a regex" {
  _1029_root
  run bash "$root/scripts/next.sh" volk --through 'clean.*'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step 'clean.*' (not present in"* ]]
  [[ "$output" != *"older revision block"* ]]
  [[ "$output" != *"dispatch:"* ]]
}

@test "#1029: explicit --through cleanup on a renumbered Revision 2 dispatches cleanup" {
  _1029_root
  _1029_issue9
  run bash "$root/scripts/next.sh" volk --through cleanup
  echo "$output"
  [[ "$output" == *"dispatch: volk/Issue-676 — step 24 (cleanup)"* ]]
  [[ "$output" != *"unknown step"* ]]
  [[ "$output" != *"older revision block"* ]]
}

@test "#1029: a target that leaves the active block mid-chain stops the chain with the refusal" {
  _1029_root
  local cl="$DEVDOC/Issue-676/checklist.md"
  cat > "$cl" <<'EOC'
## Revision 1

- [ ]  0. pull
- [ ]  3. spike
- [ ]  4. scope
- [ ] 24. cleanup
EOC
  cat > "$BATS_TEST_TMPDIR/after.md" <<'EOC'
## Revision 1

- [x]  0. pull
- [ ]  3. spike
- [ ]  4. scope
- [ ] 24. cleanup

## Revision 2

- [ ]  2. draft
- [ ] 24. cleanup
EOC
  # pull's stub starts a new revision that lacks the target, as a mid-chain
  # /devagent:revise would.
  printf '#!/usr/bin/env bash\ncp "%s" "%s"\necho STUB-pull\nexit 0\n' \
    "$BATS_TEST_TMPDIR/after.md" "$cl" > "$root/scripts/pull.sh"
  run bash "$root/scripts/next.sh" volk --through spike
  echo "$output"
  [[ "$output" == *"STUB-pull"* ]]
  [ "$status" -ne 0 ]
  [[ "$output" == *"--through 'spike': that step is only in an older revision block of"* ]]
  [[ "$output" != *"dispatch: volk/Issue-676 — step 2 (draft)"* ]]
}


# --- #880: a STUCK [!] outside the active revision block ---------------------
# _stall_fixture: an older-block [!] (Revision 1) with Revision 2 active. The
# `## Log` section sits between the blocks, as revise.sh leaves it; unstuck.sh's
# log_append needs one.
_stall_fixture() {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
## Revision 1

- [x]  0. pull
- [x]  2. draft
- [!] 15. review

## Log

## Revision 2

- [x]  2. draft
- [ ] 15. review
- [ ] 24. cleanup
EOC
}

_stall_sentinel() {
  printf 'Step:        15 review\nReason:      reviewer unavailable\n' > "$DEVDOC/Issue-676/STUCK"
}

_bang_line() { grep -nE '^- \[!\]' "$DEVDOC/Issue-676/checklist.md" | head -1 | cut -d: -f1; }

@test "#880 next halts on a STUCK [!] in an older revision block" {
  _stall_fixture; _stall_sentinel
  local f="$DEVDOC/Issue-676/checklist.md" bang before
  bang="$(_bang_line)"; [ -n "$bang" ]
  before="$(sha256sum "$f")"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 15 (review) at line $bang, Revision 1 (an older block; the active block is Revision 2) is marked [!]. Run /devagent:unstuck to clear."* ]]
  [[ "$output" == *"reviewer unavailable"* ]]
  [[ "$output" != *"dispatch:"* ]]
  [[ "$output" != *"CHAIN:"* ]]
  [ "$(sha256sum "$f")" = "$before" ]
}

@test "#880 next --auto halts on a STUCK [!] in an older revision block" {
  _stall_fixture; _stall_sentinel
  local f="$DEVDOC/Issue-676/checklist.md" bang before
  bang="$(_bang_line)"; [ -n "$bang" ]
  before="$(sha256sum "$f")"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 15 (review) at line $bang, Revision 1 (an older block; the active block is Revision 2) is marked [!]. Run /devagent:unstuck to clear."* ]]
  [[ "$output" == *"reviewer unavailable"* ]]
  [[ "$output" != *"dispatch:"* ]]
  [[ "$output" != *"CHAIN:"* ]]
  [ "$(sha256sum "$f")" = "$before" ]
}

@test "#880 a STUCK [!] in the active block that is not the current step halts" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
## Revision 1

- [x]  0. pull
- [x]  2. draft

## Log

## Revision 2

- [ ]  2. draft
- [!] 15. review
- [ ] 24. cleanup
EOC
  _stall_sentinel
  local bang; bang="$(_bang_line)"; [ -n "$bang" ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 15 (review) at line $bang, Revision 2 (the active block) is marked [!]. Run /devagent:unstuck to clear."* ]]
  [[ "$output" != *"dispatch:"* ]]
}

@test "#880 an older-block stall halts even when the active block is complete" {
  _stall_fixture; _stall_sentinel
  sed -i -e 's/^- \[ \] 15\. review/- [x] 15. review/' -e 's/^- \[ \] 24\. cleanup/- [x] 24. cleanup/' \
    "$DEVDOC/Issue-676/checklist.md"
  local bang; bang="$(_bang_line)"; [ -n "$bang" ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 15 (review) at line $bang, Revision 1 (an older block; the active block is Revision 2) is marked [!]."* ]]
  [[ "$output" != *"All steps complete"* ]]
}

@test "#880 gate (a) keeps its message for the active block's current [!]" {
  # Preservation leg: green at HEAD by design.
  sed -i 's/^- \[ \]  4\. scope/- [!]  4. scope/' "$DEVDOC/Issue-676/checklist.md"
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 4 (scope) is marked [!]. Run /devagent:unstuck to clear."* ]]
  [[ "$output" != *"at line"* ]]
}

@test "#880 a STUCK [!] on the current step halts even when the --through target is complete" {
  sed -i 's/^- \[ \]  4\. scope/- [!]  4. scope/' "$DEVDOC/Issue-676/checklist.md"
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through draft
  [ "$status" -eq 1 ]
  [[ "$output" == *"STUCK: step 4 (scope) is marked [!]. Run /devagent:unstuck to clear."* ]]
  [[ "$output" == *"Reason: blocked"* ]]
  [[ "$output" != *"Chain target"* ]]
}

@test "#880 an orphan older-block [!] with no STUCK warns once and dispatches as today" {
  _stall_fixture
  local bang; bang="$(_bang_line)"; [ -n "$bang" ]
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch: volk/Issue-676 — step 15 (review), skill-backed"* ]]
  [ "$(grep -c 'WARNING:' <<<"$stderr")" -eq 1 ]
  local w; w="$(grep 'WARNING:' <<<"$stderr")"
  [[ "$w" == *"line $bang"* ]]
  [[ "$w" == *"no STUCK file at $DEVDOC/Issue-676/STUCK"* ]]
}

@test "#880 a STUCK file with no [!] row warns once and dispatches as today" {
  _stall_fixture; _stall_sentinel
  sed -i 's/^- \[!\] 15\. review/- [x] 15. review/' "$DEVDOC/Issue-676/checklist.md"
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch: volk/Issue-676 — step 15 (review), skill-backed"* ]]
  [ "$(grep -c 'WARNING:' <<<"$stderr")" -eq 1 ]
  [[ "$(grep 'WARNING:' <<<"$stderr")" == *"$DEVDOC/Issue-676/STUCK is present but no row in"* ]]
}

@test "#880 a STUCK directory beside an older-block [!] warns it is not a regular file" {
  _stall_fixture
  mkdir "$DEVDOC/Issue-676/STUCK"
  local bang; bang="$(_bang_line)"; [ -n "$bang" ]
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch: volk/Issue-676 — step 15 (review), skill-backed"* ]]
  [ "$(grep -c 'WARNING:' <<<"$stderr")" -eq 1 ]
  local w; w="$(grep 'WARNING:' <<<"$stderr")"
  [[ "$w" == *"line $bang"* ]]
  [[ "$w" == *"$DEVDOC/Issue-676/STUCK is not a regular file, so /devagent:unstuck will not clear it"* ]]
}

@test "#880 the halt's remedy clears the stall and next proceeds" {
  _stall_fixture; _stall_sentinel
  local f="$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"Run /devagent:unstuck to clear."* ]]
  # Follow the printed remedy, then assert the recovered state.
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  local rev2 row
  rev2="$(grep -n '^## Revision 2' "$f" | cut -d: -f1)"; [ -n "$rev2" ]
  [ "$(grep -cE '^- \[~\][[:space:]]+15\. review' "$f")" -eq 1 ]
  row="$(grep -nE '^- \[~\][[:space:]]+15\. review' "$f" | cut -d: -f1)"
  [ "$row" -lt "$rev2" ]
  run --separate-stderr "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch: volk/Issue-676 — step 15 (review)"* ]]
  [[ "$stderr" != *"WARNING:"* ]]
}
