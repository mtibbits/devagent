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

@test "next on a skill-backed step prints the slash command to invoke" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
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
  cat >> "$DA_HOME/config.toml" <<EOF

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
EOF
  DEVAGENT_ACTIVE_PROJECT=volk run "$PLUGIN_ROOT/scripts/next.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/devagent:scope"* ]]
}

@test "next with no project arg dies when multiple projects configured" {
  cat >> "$DA_HOME/config.toml" <<EOF

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
EOF
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
  cat >> "$DA_HOME/config.toml" <<CFG

[project.other]
source_dir = "$BATS_TEST_TMPDIR/other"
devdoc_dir = "$BATS_TEST_TMPDIR/other-devdoc"
CFG
  cat > "$DA_HOME/state/other.toml" <<ST
active_issue = "Issue-999"
issue_dir    = "$BATS_TEST_TMPDIR/other-devdoc/Issue-999"
ST
  # The cleanup row is LOAD-BEARING: `--auto` implies `--through cleanup`
  # (next.sh:61-63), and hop 2 validates that target against the RESOLVED
  # project's checklist (:66-76). Without the row the unfixed tree dies
  # "unknown step 'cleanup'" before dispatching anything, and the born-red
  # would fire on a path unrelated to the hijack (register Issue-Fork-132).
  cat > "$BATS_TEST_TMPDIR/other-devdoc/Issue-999/checklist.md" <<'CL'
- [x]  0. pull
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
}

@test "skill dispatch names the resolved project and issue (#578)" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk/Issue-676"* ]]
  [[ "$output" == *"/devagent:scope volk"* ]]   # the invoked command carries its scope
}
