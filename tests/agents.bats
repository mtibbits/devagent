#!/usr/bin/env bats
# #458: the dedicated checker agents for steps 14 (redmr) and 21 (preship).
# #527: + the step-3 (improve) agent — same structural pins, third row.
#
# These agents are the STRUCTURAL half of fresh-context checking: the isolation
# is enforced by the harness (tool denial + pinned model + system prompt) rather
# than depending on the model choosing to spawn a generic subagent correctly.
# The named failure mode is silently-ignored frontmatter — `claude plugin
# validate --strict` never opens these files (verified 2.1.211), so these
# canaries plus the live smoke test are the only gates. Field spellings are
# probe-verified: agents take `disallowedTools` (camelCase); the hyphenated
# `disallowed-tools` is the SKILL.md spelling and is silently ignored here.

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."
PRESHIP="$REPO/agents/preship-verifier.md"
REDTEAM="$REPO/agents/redteam-reviewer.md"
IMPROVE="$REPO/agents/plan-improver.md"

# Read each frontmatter ONCE per test rather than re-awking per assertion.
setup() {
    FM_PRESHIP="$(skill_frontmatter "$PRESHIP")"
    FM_REDTEAM="$(skill_frontmatter "$REDTEAM")"
    FM_IMPROVE="$(skill_frontmatter "$IMPROVE")"
}

@test "all three checker agents exist at the plugin's auto-discovered agents/ root (#458/#527)" {
  # agents/ is scanned by default; plugin.json must NOT gain an "agents" key —
  # that REPLACES the default scan rather than adding to it.
  [ -s "$PRESHIP" ]
  [ -s "$REDTEAM" ]
  [ -s "$IMPROVE" ]
  run grep -c '"agents"' "$REPO/.claude-plugin/plugin.json"
  [ "$output" -eq 0 ]
}

@test "agent identity comes from name: frontmatter and matches its binding (#458/#527)" {
  run grep -c '^name: preship-verifier$' <<<"$FM_PRESHIP"
  [ "$output" -eq 1 ]
  run grep -c '^name: redteam-reviewer$' <<<"$FM_REDTEAM"
  [ "$output" -eq 1 ]
  run grep -c '^name: plan-improver$' <<<"$FM_IMPROVE"
  [ "$output" -eq 1 ]
  # The skills bind these exact names; a typo'd agent: silently falls back to
  # general-purpose (no system prompt, no tool denial, no isolation).
  run grep -c '^agent: devagent:preship-verifier$' "$REPO/skills/core-preship/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:redteam-reviewer$' "$REPO/skills/core-redmr/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:plan-improver$' "$REPO/skills/core-improve/SKILL.md"
  [ "$output" -eq 1 ]
}

@test "all checker agents deny Write/Edit with the camelCase agent spelling (#458/#527)" {
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM" "$FM_IMPROVE"; do
    run grep -c '^disallowedTools:' <<<"$fm"
    [ "$output" -eq 1 ] || { echo "no disallowedTools in: $fm" >&2; false; }
    grep -qE '^disallowedTools:.*\bWrite\b' <<<"$fm"
    grep -qE '^disallowedTools:.*\bEdit\b' <<<"$fm"
    # The hyphenated skill spelling here would be silently ignored — the exact
    # failure mode this issue exists to close.
    run grep -c '^disallowed-tools:' <<<"$fm"
    [ "$output" -eq 0 ] || { echo "uses the SKILL spelling (silently ignored on agents)" >&2; false; }
  done
}

@test "checker agents pin effort but MUST NOT pin model (#458 redmr BLOCKING)" {
  # Measured at 2.1.211: the Agent tool's model param is a closed enum
  # (sonnet|opus|haiku|fable) with NO inherit value, and omitting the param
  # resolves to "the agent definition's model, or inherits from the parent".
  # So a frontmatter model pin makes the #291 'inherit' escape (rc 2)
  # unreachable — the pinned model wins on every dispatch shape. The step
  # default therefore lives in the WRAPPERS (rc-3 row); the agents stay
  # unpinned so the rc-2 skill-fork genuinely inherits the session model
  # (transcript-verified: unpinned fork ran the main chain's model).
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM" "$FM_IMPROVE"; do
    grep -qE '^effort:[[:space:]]+(low|medium|high|xhigh|max)$' <<<"$fm"
    run grep -c '^model:' <<<"$fm"
    [ "$output" -eq 0 ] || { echo "agent pins a model — rc 2 becomes unreachable" >&2; false; }
  done
}

@test "preship-verifier names all five verifications (#458)" {
  grep -qi 'acceptance criteria' "$PRESHIP"
  grep -qi 'findings applied' "$PRESHIP"
  grep -qi 'push preview' "$PRESHIP"
  grep -qi 'evidence cross-check' "$PRESHIP"
  grep -qi 'spec-touch' "$PRESHIP"
}

@test "redteam-reviewer carries the severity taxonomy and template precedence (#458)" {
  local t
  for t in '[BLOCKING]' '[MAJOR]' '[MINOR]' '[INFO]'; do
    grep -qF "$t" "$REDTEAM" || { echo "missing severity tag: $t" >&2; false; }
  done
  # §12 registry stays authoritative for WHAT to attack; this file owns OUTPUT.
  grep -qF 'redteam_mr' "$REDTEAM"
  grep -qi 'authority for WHAT to attack' "$REDTEAM"
  # The statusreport-parsed count line is contract.
  grep -qF 'B blocking, M major, m minor, I info' "$REDTEAM"
}

@test "plan-improver names the three categories, the pothole tripwire, and self-resolves the register (#527)" {
  # The procedure moved skill→agent; these content pins moved with it. The
  # register self-resolution is AC4's mechanism: the #286 tripwire's input is
  # no longer a dispatch-packaging line that can silently rot (dead-tripwire
  # class) — the agent resolves `potholes` via the §12 walk itself.
  grep -qi 'bug' "$IMPROVE"
  grep -qi 'side effect' "$IMPROVE"
  grep -qi 'ambiguit' "$IMPROVE"
  grep -qi 'Pothole register tripwire' "$IMPROVE"
  grep -qF 'show potholes' "$IMPROVE"
  grep -qF 'template.sh' "$IMPROVE"
  # Findings return UNTAGGED — [merge]/[defer]/[dismiss] triage is the main
  # session's judgment, and the count line matches the wrapper's log format.
  grep -qF 'B bugs, S side-effects, A ambiguities' "$IMPROVE"
}

@test "all checker agents return the artifact instead of writing it (#458/#527)" {
  local f
  for f in "$PRESHIP" "$REDTEAM" "$IMPROVE"; do
    grep -qi 'cannot write files' "$f"
    grep -qi 'final message' "$f"
    # context: subagent is the linter's required token; a fork must never stamp
    # 'context: fork' into an artifact header.
    grep -qF 'context: subagent' "$f"
    grep -qi 'never .*context: fork' "$f"
  done
}
